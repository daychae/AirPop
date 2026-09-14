import AppKit
import CoreGraphics
import CoreImage

/// Layout for the "Cool" three-layer frame
/// (PhotoFrameCoolBase/PhotoFrameCoolTop in Assets.xcassets): a fixed
/// 1200x1200 square. Base carries the background art with an empty (opaque)
/// photo window; top carries bubbles that spill onto the photo's edges,
/// with a transparent center covering roughly the window area only -- NOT
/// the caption footprint below it. Base still has "AirPop & AirPuff / by L
/// & L" baked in too, but top's opaque background fully covers that
/// footprint, so the whole caption (title, "by L & L", and the live date)
/// is drawn fresh on top of everything instead. See
/// iOS_macOS_app_frames_updated/README.txt for the source spec, given in
/// top-left-origin image coordinates.
private enum FrameLayout {
  static let canvasSize = CGSize(width: 1200, height: 1200)
  static let cornerRadius: CGFloat = 24

  /// The photo window, converted from the asset's top-left-origin spec into
  /// CGContext's bottom-up coordinate space: y = canvasHeight - top - height.
  static let windowRect = CGRect(x: 140, y: 270, width: 920, height: 790)

  /// How far the photo's edge fades out, in points. A hard geometric clip
  /// on the rounded rect reads as a harsh, slightly jagged border where the
  /// sharp photo meets the frame art's own soft window edge; feathering it
  /// blends the two instead.
  static let windowEdgeFeather: CGFloat = 24
}

/// Position/type spec for the caption, measured directly off the baked
/// title/"by L & L" text in PhotoFrameCoolBase.png (top-left origin, then
/// converted to bottom-up CG coordinates the same way
/// `FrameLayout.windowRect` is) plus the date/divider spec from
/// iOS_macOS_app_frames_updated/README.txt.
private enum CaptionLayout {
  /// The `wght` axis tag ('w','g','h','t' as a big-endian UInt32), for
  /// setting Google Sans Flex's weight directly -- the abstract
  /// NSFontDescriptor weight *trait* (what the old `sfProExpanded` used for
  /// SF Pro's width axis) doesn't reliably resolve to this third-party
  /// variable font's named instances. See ContentView's `googleSansFlex`
  /// for the same technique on the SwiftUI side.
  private static let wghtAxisTag: UInt32 = 0x77_67_68_74

  static func googleSansFlex(wght: CGFloat, size: CGFloat) -> NSFont {
    let descriptor = NSFontDescriptor(fontAttributes: [
      .name: "Google Sans Flex",
      .size: size,
      .variation: [wghtAxisTag: wght],
    ])
    return NSFont(descriptor: descriptor, size: size)
      ?? NSFont.systemFont(ofSize: size, weight: .medium)
  }

  /// Twice the size the title was measured at in the baked art -- the logo
  /// can afford to read bigger than the source design.
  static let titleFontSize: CGFloat = 34 * 2
  static let titleFont = googleSansFlex(wght: 500, size: titleFontSize)
  /// Sampled from the baked title text in PhotoFrameCoolBase.png -- still
  /// the old square frame's color; due for a re-sample once the new wide
  /// frame (blue "AirPop", per the latest mockup) actually lands as a file.
  static let titleColor = NSColor(
    calibratedRed: CGFloat(0x3A) / 255, green: CGFloat(0x4A) / 255,
    blue: CGFloat(0xA8) / 255, alpha: 1)
  /// Center of the title, at x600,y1039 (top-left origin) -- the midpoint
  /// of "AirPop & AirPuff"'s measured bounding box in the baked art, kept
  /// as the center even though the title itself now reads just "AirPop"
  /// and is drawn larger.
  static let titleCenter = CGPoint(x: 600, y: canvasHeight - 1039)

  /// "by L & L", the date, and the divider between them all share one
  /// row/font size, sitting on the same baseline band as "by L & L" in the
  /// baked art (y 1106...1131, center 1118.5, matching the README's date
  /// baseline band of y 1099...1135, center 1117). "by L & L" is Google
  /// Sans Flex like the title; the date is Google Sans Code Medium (a
  /// separate bundled font -- Fonts/GoogleSansCode-Medium.ttf) for a
  /// monospaced, code-like read.
  static let fontSize: CGFloat = 27
  static let byLineFont = googleSansFlex(wght: 500, size: fontSize)
  static let dateFont =
    NSFont(name: "GoogleSansCode-Medium", size: fontSize)
    ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
  /// The date and divider keep the spec's 0.24em; "by L & L" reads too
  /// loose at that tracking, so it's tightened.
  static let dateKerning: CGFloat = fontSize * 0.24
  static let byLineKerning: CGFloat = fontSize * 0.1
  /// Sampled from the baked "by L & L" text in PhotoFrameCoolBase.png.
  static let rowColor = NSColor(
    calibratedRed: CGFloat(0x3F) / 255, green: CGFloat(0x4A) / 255,
    blue: CGFloat(0x86) / 255, alpha: 1)
  static let rowCenterY = canvasHeight - 1117
  /// Center of the date text specifically, at x713 (top-left origin) in
  /// the README's spec.
  static let dateCenterX: CGFloat = 713
  static let dividerSize = CGSize(width: 2, height: 26)
  static let dividerGap: CGFloat = 22
  static let dividerColor = NSColor(
    calibratedRed: CGFloat(0x8A) / 255, green: CGFloat(0x93) / 255,
    blue: CGFloat(0xC8) / 255, alpha: 1)

  private static let canvasHeight: CGFloat = FrameLayout.canvasSize.height
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
      let windowPath = CGPath(
        roundedRect: FrameLayout.windowRect,
        cornerWidth: FrameLayout.cornerRadius,
        cornerHeight: FrameLayout.cornerRadius,
        transform: nil
      )
      context.addPath(windowPath)
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
      // matches the on-screen game window, not the frame's 920x790 window,
      // so drawing it straight into `windowRect` squashed it vertically.
      // The bubbles it draws are the only game content that belongs in the
      // photo -- no score/combo text.
      drawAspectFill(overlayImage, in: FrameLayout.windowRect, context: context)
    }

    context.restoreGState()

    // Bubbles that spill onto the photo's edges, with a transparent center,
    // drawn after the photo so they sit on top of it near the border.
    if let topCGImage {
      context.draw(topCGImage, in: CGRect(origin: .zero, size: outputSize))
    }

    // PhotoFrameCoolTop's own transparent center is an oval that falls well
    // short of the window's straight top/bottom edges, so its fog is still
    // heavy for a while in from those edges -- measured off its alpha
    // channel, essentially fully opaque at the very edge, only clearing by
    // roughly 85pt in at the top and 180pt in at the bottom. Rather than
    // fight that with more masking/feathering (which kept reading as a
    // seam at every radius tried), a few more bubbles straddling those
    // edges -- half over the photo, half over the frame background --
    // cover the transition with the same "bubbles spilling onto the
    // photo" device the corners already use.
    drawSeamBubbles(context: context)

    drawCaption(context: context)

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
  }

  private static let baseCGImage: CGImage? = loadNamedImage("PhotoFrameCoolBase")
  private static let topCGImage: CGImage? = loadNamedImage("PhotoFrameCoolTop")
  private static let ciContext = CIContext(options: nil)

  /// A soft-edged grayscale mask the size of the whole canvas: white (fully
  /// visible) over the rounded photo window, black everywhere else, then
  /// blurred by `FrameLayout.windowEdgeFeather` so the boundary fades over
  /// a few points instead of cutting a hard geometric edge. Used with
  /// `CGContext.clip(to:mask:)` so the photo, game overlay, and dim tint
  /// all fade out together at the window's edge.
  private static func featheredWindowMask(canvasSize: CGSize) -> CGImage? {
    guard
      let maskContext = CGContext(
        data: nil,
        width: Int(canvasSize.width),
        height: Int(canvasSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return nil }
    maskContext.setFillColor(gray: 0, alpha: 1)
    maskContext.fill(CGRect(origin: .zero, size: canvasSize))
    maskContext.setFillColor(gray: 1, alpha: 1)
    maskContext.addPath(
      CGPath(
        roundedRect: FrameLayout.windowRect,
        cornerWidth: FrameLayout.cornerRadius,
        cornerHeight: FrameLayout.cornerRadius,
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
    static let lavender = NSColor(named: "Colors/Lilac")!
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
    SeamBubble(x: 0.12, radius: 95, color: BubblePalette.skyBlue),
    SeamBubble(x: 0.42, radius: 62, color: BubblePalette.pink),
    SeamBubble(x: 0.68, radius: 78, color: BubblePalette.lavender),
    SeamBubble(x: 0.90, radius: 55, color: BubblePalette.mint),
  ]
  private static let bottomSeamBubbles = [
    SeamBubble(x: 0.08, radius: 85, color: BubblePalette.peach),
    SeamBubble(x: 0.36, radius: 105, color: BubblePalette.lavender),
    SeamBubble(x: 0.64, radius: 72, color: BubblePalette.skyBlue),
    SeamBubble(x: 0.88, radius: 95, color: BubblePalette.pink),
  ]

  /// Centering bubbles exactly on the window's outer edge missed the actual
  /// fog transition, which (per PhotoFrameCoolTop's alpha channel) sits
  /// further inside -- about 85pt in at the top, 180pt in at the bottom
  /// (the bottom oval falls shorter). Pulling the centers in by roughly
  /// half that keeps the transition inside each bubble's radius.
  private static let topSeamInset: CGFloat = 55
  private static let bottomSeamInset: CGFloat = 95

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

  /// A simplified version of GameScene's frosted-glass bubble: a radial
  /// gradient fill (bright highlight fading to the tint), a soft outer
  /// glow, and a white rim, so these read as the same bubble family as the
  /// gameplay bubbles and the frame's own corner bubbles.
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

  /// Draws the whole caption -- title, "by L & L", the divider, and the
  /// live capture date -- fresh on top of everything else. PhotoFrameCoolTop
  /// covers all of this footprint in the baked art (its transparent center
  /// only reaches the photo window, not the caption below it), so none of
  /// it would otherwise be visible.
  private static func drawCaption(context: CGContext) {
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let title = NSAttributedString(
      string: "AirPop",
      attributes: [
        .font: CaptionLayout.titleFont,
        .foregroundColor: CaptionLayout.titleColor,
      ]
    )
    let titleSize = title.size()
    title.draw(
      at: CGPoint(
        x: CaptionLayout.titleCenter.x - titleSize.width / 2,
        y: CaptionLayout.titleCenter.y - titleSize.height / 2
      )
    )

    let byLine = NSAttributedString(
      string: "by L & L",
      attributes: [
        .font: CaptionLayout.byLineFont,
        .foregroundColor: CaptionLayout.rowColor,
        .kern: CaptionLayout.byLineKerning,
      ]
    )
    let dateText = NSAttributedString(
      string: captionDateFormatter.string(from: Date()),
      attributes: [
        .font: CaptionLayout.dateFont,
        .foregroundColor: CaptionLayout.rowColor,
        .kern: CaptionLayout.dateKerning,
      ]
    )

    let dateSize = dateText.size()
    let dateOrigin = CGPoint(
      x: CaptionLayout.dateCenterX - dateSize.width / 2,
      y: CaptionLayout.rowCenterY - dateSize.height / 2
    )
    dateText.draw(at: dateOrigin)

    let dividerRect = CGRect(
      x: dateOrigin.x - CaptionLayout.dividerGap - CaptionLayout.dividerSize.width,
      y: CaptionLayout.rowCenterY - CaptionLayout.dividerSize.height / 2,
      width: CaptionLayout.dividerSize.width,
      height: CaptionLayout.dividerSize.height
    )

    let byLineSize = byLine.size()
    byLine.draw(
      at: CGPoint(
        x: dividerRect.minX - CaptionLayout.dividerGap - byLineSize.width,
        y: CaptionLayout.rowCenterY - byLineSize.height / 2
      )
    )

    NSGraphicsContext.restoreGraphicsState()

    context.setFillColor(CaptionLayout.dividerColor.cgColor)
    context.fill(dividerRect)
  }

  /// Aspect-fill crops symmetrically by default, but the window (920x790,
  /// close to square) is much shorter than the game window it's capturing
  /// from, so a centered crop was cutting off both the top of the player's
  /// head and their chest/shoulders. Weighting the vertical crop toward the
  /// top keeps the head in frame and lets the extra cropping fall on the
  /// body below instead, which the seam bubbles at the bottom edge (see
  /// `drawSeamBubbles`) already help cover rather than cutting hard.
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
