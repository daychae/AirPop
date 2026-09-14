import AppKit
import CoreGraphics
import CoreImage

/// Layout for the square frame (`PhotoFrameSquare` in Assets.xcassets): a
/// fixed 1200x1200 canvas, single layer, no caption baked in -- this art
/// ships as pure background/bubble decoration, so the whole caption (logo,
/// "by L & L | date") is drawn fresh every time, and a ring of seam bubbles
/// is drawn at the photo window's edges to match a past version of this
/// screen the design is meant to echo.
private enum FrameLayout {
  static let canvasSize = CGSize(width: 1200, height: 1200)

  /// The photo window, picked to fill the art's bright "clearing" while
  /// leaving enough room below for the two-line caption. A rounded rect
  /// (not the oval used briefly in between) to match the reference this
  /// was asked to echo, and deliberately close enough to the ring of
  /// bubbles above/below that `seamBubbles` reads as sitting right on the
  /// window's edge rather than floating apart from it.
  static let windowRect = CGRect(x: 150, y: 500, width: 900, height: 600)
  static let windowCornerRadius: CGFloat = 40

  /// The oval window elsewhere in this app only needed a little smoothing
  /// since its edge in the art itself is already soft; this rect's corners
  /// are a hard geometric cut with nothing like that to lean on, so it
  /// needs more blur to keep the hand-off from reading as jagged.
  static let windowEdgeFeather: CGFloat = 16
}

/// The whole caption is drawn fresh in white (no baked art to match), with
/// a soft shadow for legibility against the frame's own pale background --
/// plain white-on-white read as barely-there otherwise.
private enum CaptionLayout {
  private static let wghtAxisTag: UInt32 = 0x77_67_68_74

  /// Same technique as ContentView's `googleSansFlex`: the abstract weight
  /// *trait* doesn't reliably resolve this third-party variable font's
  /// named instances, so the `wght` axis is set directly.
  static func googleSansFlex(wght: CGFloat, size: CGFloat) -> NSFont {
    let descriptor = NSFontDescriptor(fontAttributes: [
      .name: "Google Sans Flex",
      .size: size,
      .variation: [wghtAxisTag: wght],
    ])
    return NSFont(descriptor: descriptor, size: size)
      ?? NSFont.systemFont(ofSize: size, weight: .medium)
  }

  static let textColor = NSColor.white
  static let rowColor = NSColor.white.withAlphaComponent(0.92)
  static let shadowColor = NSColor.black.withAlphaComponent(0.4)
  static let shadowBlur: CGFloat = 7

  static let logoFont = googleSansFlex(wght: 500, size: 74)
  /// "AirPop" reads with an odd gap between "o" and "p" at this font's
  /// default spacing -- tightened by kerning just that one pair instead of
  /// applying tracking to the whole word.
  static let logoPopKerningRange = NSRange(location: 4, length: 1)
  static let logoPopKerning: CGFloat = -logoFont.pointSize * 0.045
  static let logoCenter = CGPoint(x: 600, y: 400)

  static let byLineFont = googleSansFlex(wght: 500, size: 22)
  static let byLineKerning: CGFloat = byLineFont.pointSize * 0.1
  static let dividerColor = NSColor.white.withAlphaComponent(0.6)

  /// Handjet is a seven-segment-display-style face -- the faint "ghost"
  /// segments behind each lit digit are intentional to the font, not a
  /// rendering glitch, and read well as a photo-booth-style date stamp.
  static let dateFont =
    NSFont(name: "Handjet-SemiBold", size: 26)
    ?? NSFont.monospacedSystemFont(ofSize: 26, weight: .semibold)
  static let dateKerning: CGFloat = dateFont.pointSize * 0.12
  static let rowCenter = CGPoint(x: 600, y: 330)
}

enum ResultPhotoComposer {
  static func make(
    cameraImage: CGImage,
    overlayImage: CGImage?,
    canvasSize: CGSize
  ) -> NSImage? {
    guard canvasSize.width > 1, canvasSize.height > 1 else { return nil }

    let outputSize = FrameLayout.canvasSize

    guard
      let context = CGContext(
        data: nil,
        width: Int(outputSize.width),
        height: Int(outputSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }

    if let baseCGImage {
      context.draw(baseCGImage, in: CGRect(origin: .zero, size: outputSize))
    }

    context.saveGState()
    if let mask = featheredWindowMask(canvasSize: outputSize) {
      context.clip(to: CGRect(origin: .zero, size: outputSize), mask: mask)
    } else {
      context.addPath(
        CGPath(
          roundedRect: FrameLayout.windowRect,
          cornerWidth: FrameLayout.windowCornerRadius,
          cornerHeight: FrameLayout.windowCornerRadius,
          transform: nil
        )
      )
      context.clip()
    }

    drawMirroredAspectFill(
      cameraImage,
      in: FrameLayout.windowRect,
      context: context
    )

    // Lightened from 0.16 -- a dim real-world photo read noticeably heavy
    // at the darker tint.
    context.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    context.fill(FrameLayout.windowRect)

    if let overlayImage {
      // Aspect-fill like the camera layer, not a plain stretch-to-rect draw:
      // the SpriteKit scene's aspect ratio (scene.size, i.e. `canvasSize`)
      // matches the on-screen game window, not the frame's window, so
      // drawing it straight into `windowRect` would squash it. The bubbles
      // it draws are the only game content that belongs in the photo -- no
      // score/combo text.
      drawAspectFill(overlayImage, in: FrameLayout.windowRect, context: context)
    }

    context.restoreGState()

    drawSeamBubbles(context: context)
    drawCaption(context: context)

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
  }

  private static let baseCGImage: CGImage? = loadNamedImage("PhotoFrameSquare")
  private static let ciContext = CIContext(options: nil)

  /// A soft-edged mask the size of the whole canvas: opaque over the photo
  /// window, transparent everywhere else, then blurred by
  /// `FrameLayout.windowEdgeFeather` so the boundary fades over a few
  /// points instead of cutting a hard geometric edge. Used with
  /// `CGContext.clip(to:mask:)` so the photo, game overlay, and dim tint
  /// all fade out together at the window's edge.
  ///
  /// `clip(to:mask:)` reads coverage from the mask image's *alpha*
  /// channel, not from a grayscale color value -- a mask built the more
  /// obvious way (white-on-black in a context with no alpha channel at
  /// all) is treated as fully opaque everywhere, and clips nothing.
  private static func featheredWindowMask(canvasSize: CGSize) -> CGImage? {
    guard
      let maskContext = CGContext(
        data: nil,
        width: Int(canvasSize.width),
        height: Int(canvasSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
      )
    else { return nil }
    maskContext.setFillColor(gray: 0, alpha: 0)
    maskContext.fill(CGRect(origin: .zero, size: canvasSize))
    maskContext.setFillColor(gray: 0, alpha: 1)
    maskContext.addPath(
      CGPath(
        roundedRect: FrameLayout.windowRect,
        cornerWidth: FrameLayout.windowCornerRadius,
        cornerHeight: FrameLayout.windowCornerRadius,
        transform: nil
      )
    )
    maskContext.fillPath()
    guard let rawMask = maskContext.makeImage() else { return nil }

    let ciMask = CIImage(cgImage: rawMask)
    guard let blur = CIFilter(name: "CIGaussianBlur") else { return rawMask }
    blur.setValue(ciMask.clampedToExtent(), forKey: kCIInputImageKey)
    blur.setValue(FrameLayout.windowEdgeFeather, forKey: kCIInputRadiusKey)
    guard
      let output = blur.outputImage?.cropped(to: ciMask.extent),
      let blurredMask = ciContext.createCGImage(output, from: ciMask.extent)
    else { return rawMask }
    return blurredMask
  }

  /// The five pastel colors used across the AirPuff/AirPop bubble design
  /// system, matching GameScene's BubblePalette and ContentView's Brand.
  /// Backed by the designer's handoff color set (`Assets.xcassets/Colors`)
  /// instead of hand-picked hex -- see ContentView's `Brand` enum for the
  /// full mapping.
  private enum BubblePalette {
    static let skyBlue = NSColor(named: "Colors/Sky")!
    static let lilac = NSColor(named: "Colors/Lilac")!
    static let mint = NSColor(named: "Colors/Aqua")!
    static let pink = NSColor(named: "Colors/Blossom")!
    static let peach = NSColor(named: "Colors/Apricot")!
  }

  private struct SeamBubble {
    let x: CGFloat
    let radius: CGFloat
    let color: NSColor
  }

  /// Fixed, not random: the same photo composited twice should look the
  /// same. x is a fraction of the window's width from its left edge.
  private static let topSeamBubbles = [
    SeamBubble(x: 0.12, radius: 60, color: BubblePalette.skyBlue),
    SeamBubble(x: 0.38, radius: 42, color: BubblePalette.pink),
    SeamBubble(x: 0.62, radius: 48, color: BubblePalette.lilac),
    SeamBubble(x: 0.88, radius: 40, color: BubblePalette.mint),
  ]
  private static let bottomSeamBubbles = [
    SeamBubble(x: 0.10, radius: 55, color: BubblePalette.peach),
    SeamBubble(x: 0.36, radius: 65, color: BubblePalette.lilac),
    SeamBubble(x: 0.64, radius: 48, color: BubblePalette.skyBlue),
    SeamBubble(x: 0.90, radius: 58, color: BubblePalette.pink),
  ]
  private static let topSeamInset: CGFloat = 20
  private static let bottomSeamInset: CGFloat = 30

  private static func drawSeamBubbles(context: CGContext) {
    let window = FrameLayout.windowRect
    for bubble in topSeamBubbles {
      drawFrostedBubble(
        center: CGPoint(x: window.minX + window.width * bubble.x, y: window.maxY - topSeamInset),
        radius: bubble.radius,
        color: bubble.color,
        context: context
      )
    }
    for bubble in bottomSeamBubbles {
      drawFrostedBubble(
        center: CGPoint(x: window.minX + window.width * bubble.x, y: window.minY + bottomSeamInset),
        radius: bubble.radius,
        color: bubble.color,
        context: context
      )
    }
  }

  /// A frosted-glass bubble matching the frame art's own bubbles: a radial
  /// gradient fill (bright highlight fading to the tint), a soft outer
  /// glow, and a white rim.
  private static func drawFrostedBubble(
    center: CGPoint,
    radius: CGFloat,
    color: NSColor,
    context: CGContext
  ) {
    context.saveGState()
    context.setShadow(
      offset: .zero,
      blur: radius * 0.5,
      color: color.withAlphaComponent(0.45).cgColor
    )
    context.setFillColor(color.withAlphaComponent(0.001).cgColor)
    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.restoreGState()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let stops = [
      NSColor.white.withAlphaComponent(0.95).cgColor,
      color.withAlphaComponent(0.7).cgColor,
      color.withAlphaComponent(0.35).cgColor,
    ]
    guard
      let gradient = CGGradient(colorsSpace: colorSpace, colors: stops as CFArray, locations: [0, 0.55, 1])
    else { return }

    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.clip()
    let highlightCenter = CGPoint(x: center.x - radius * 0.16, y: center.y + radius * 0.18)
    context.drawRadialGradient(
      gradient,
      startCenter: highlightCenter, startRadius: 0,
      endCenter: center, endRadius: radius * 1.05,
      options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    context.saveGState()
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    context.setLineWidth(max(1.6, radius * 0.035))
    context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.restoreGState()
  }

  private static func loadNamedImage(_ name: String) -> CGImage? {
    guard let image = NSImage(named: name) else { return nil }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  private static let captionDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy.MM.dd"
    return formatter
  }()

  /// Draws the whole caption -- "AirPop" and a "by L & L | date" row below
  /// it -- fresh on top of everything else, since PhotoFrameSquare carries
  /// none of it baked in.
  private static func drawCaption(context: CGContext) {
    context.saveGState()
    context.setShadow(
      offset: .zero, blur: CaptionLayout.shadowBlur,
      color: CaptionLayout.shadowColor.cgColor
    )

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let logo = NSMutableAttributedString(
      string: "AirPop",
      attributes: [.font: CaptionLayout.logoFont, .foregroundColor: CaptionLayout.textColor]
    )
    logo.addAttribute(
      .kern, value: CaptionLayout.logoPopKerning, range: CaptionLayout.logoPopKerningRange)
    let logoSize = logo.size()
    logo.draw(
      at: CGPoint(
        x: CaptionLayout.logoCenter.x - logoSize.width / 2,
        y: CaptionLayout.logoCenter.y - logoSize.height / 2
      )
    )

    let row = NSMutableAttributedString(
      string: "by L & L",
      attributes: [
        .font: CaptionLayout.byLineFont, .foregroundColor: CaptionLayout.rowColor,
        .kern: CaptionLayout.byLineKerning,
      ]
    )
    row.append(
      NSAttributedString(
        string: "  |  ",
        attributes: [.font: CaptionLayout.byLineFont, .foregroundColor: CaptionLayout.dividerColor]
      )
    )
    row.append(
      NSAttributedString(
        string: captionDateFormatter.string(from: Date()),
        attributes: [
          .font: CaptionLayout.dateFont, .foregroundColor: CaptionLayout.rowColor,
          .kern: CaptionLayout.dateKerning,
        ]
      )
    )
    let rowSize = row.size()
    row.draw(
      at: CGPoint(
        x: CaptionLayout.rowCenter.x - rowSize.width / 2,
        y: CaptionLayout.rowCenter.y - rowSize.height / 2
      )
    )

    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()
  }

  /// Aspect-fill crops symmetrically by default, but the window is shorter
  /// (relative to its width) than the game window it's capturing from, so a
  /// centered crop was cutting off both the top of the player's head and
  /// their chest/shoulders. Weighting the vertical crop toward the top
  /// keeps the head in frame and lets the extra cropping fall on the body
  /// below instead, which the seam bubbles at the window's edges already
  /// help cover rather than cutting hard.
  private static let verticalCropBias: CGFloat = 0.85

  private static func aspectFillRect(source: CGSize, in bounds: CGRect) -> CGRect {
    let scale = max(
      bounds.width / source.width,
      bounds.height / source.height
    )
    let drawSize = CGSize(width: source.width * scale, height: source.height * scale)
    return CGRect(
      x: (bounds.width - drawSize.width) * 0.5,
      y: (bounds.height - drawSize.height) * verticalCropBias,
      width: drawSize.width,
      height: drawSize.height
    )
  }

  private static func drawMirroredAspectFill(
    _ image: CGImage,
    in bounds: CGRect,
    context: CGContext
  ) {
    let drawRect = aspectFillRect(source: CGSize(width: image.width, height: image.height), in: bounds)

    context.saveGState()
    context.translateBy(x: bounds.origin.x, y: bounds.origin.y)
    context.translateBy(x: bounds.width, y: 0)
    context.scaleBy(x: -1, y: 1)
    context.interpolationQuality = .high
    context.draw(image, in: drawRect)
    context.restoreGState()
  }

  /// Same aspect-fill as `drawMirroredAspectFill`, without the horizontal
  /// flip: the SpriteKit overlay is already drawn in mirrored screen space
  /// (bubble positions come from `CameraCoordinateMapper`-translated hand
  /// coordinates, which already account for the camera mirroring), so
  /// flipping it again here would misalign bubbles from where they were
  /// popped relative to the mirrored camera feed.
  private static func drawAspectFill(
    _ image: CGImage,
    in bounds: CGRect,
    context: CGContext
  ) {
    let drawRect = aspectFillRect(source: CGSize(width: image.width, height: image.height), in: bounds)

    context.saveGState()
    context.translateBy(x: bounds.origin.x, y: bounds.origin.y)
    context.interpolationQuality = .high
    context.draw(image, in: drawRect)
    context.restoreGState()
  }

}
