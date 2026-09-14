import AppKit
import CoreGraphics
import CoreImage

/// Layout for the square frame (`PhotoFrameSquare` in Assets.xcassets): a
/// fixed 1200x1200 canvas, single layer, no caption baked in -- unlike the
/// earlier wide frame, this art ships as pure background/bubble decoration,
/// so the whole caption (logo, tagline, date, "by lauren & luke") is drawn
/// fresh every time instead of covering baked text.
private enum FrameLayout {
  static let canvasSize = CGSize(width: 1200, height: 1200)

  /// The oval photo window, picked to fill the art's bright "clearing"
  /// without cutting into the bubbles ringing it (checked by eye against
  /// the actual asset, not measured off a spec). Must fully contain the
  /// asset's own baked transparent hole (top-left bbox roughly x353-846,
  /// y281-714) -- falling short there leaves a gap where neither this
  /// window's clipped content nor the base art (transparent there) paints
  /// anything, showing as a raw black notch.
  static let windowRect = CGRect(x: 150, y: 470, width: 900, height: 610)

  /// The oval's own edge in the art is already soft (a faint glow ring),
  /// so this only needs to smooth the hand-off between that and the photo.
  static let windowEdgeFeather: CGFloat = 10
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
  static let shadowColor = NSColor.black.withAlphaComponent(0.4)
  static let shadowBlur: CGFloat = 7

  static let logoFont = googleSansFlex(wght: 500, size: 74)
  /// "AirPop" reads with an odd gap between "o" and "p" at this font's
  /// default spacing -- tightened by kerning just that one pair instead of
  /// applying tracking to the whole word.
  static let logoPopKerningRange = NSRange(location: 4, length: 1)
  static let logoPopKerning: CGFloat = -logoFont.pointSize * 0.045
  static let logoCenter = CGPoint(x: 600, y: 460)

  static let taglineFont = googleSansFlex(wght: 400, size: 30)
  /// The "+"/"÷" separators between words sit a size down from the words
  /// themselves, matching the previous frame's baked tagline.
  static let taglineSymbolFont = googleSansFlex(wght: 400, size: 19)
  static let taglineCenter = CGPoint(x: 600, y: 400)

  /// Handjet is a display/monospace face (digital-clock-ish digits), which
  /// reads better as a "code-like" date stamp than a humanist sans would.
  static let dateFont =
    NSFont(name: "Handjet-SemiBold", size: 34)
    ?? NSFont.monospacedSystemFont(ofSize: 34, weight: .semibold)
  static let dateCenter = CGPoint(x: 600, y: 335)

  static let creditFont = googleSansFlex(wght: 500, size: 19)
  static let creditColor = NSColor.white.withAlphaComponent(0.9)
  static let creditCenter = CGPoint(x: 870, y: 45)
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
      context.addEllipse(in: FrameLayout.windowRect)
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

    drawCaption(context: context)

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
  }

  private static let baseCGImage: CGImage? = loadNamedImage("PhotoFrameSquare")
  private static let ciContext = CIContext(options: nil)

  /// A soft-edged mask the size of the whole canvas: opaque over the oval
  /// photo window, transparent everywhere else, then blurred by
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
    maskContext.addEllipse(in: FrameLayout.windowRect)
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

  /// Draws the whole caption -- logo, tagline, live date, and the "by
  /// lauren & luke" credit -- fresh on top of everything else, since
  /// PhotoFrameSquare carries none of it baked in.
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

    func taglineRun(_ text: String, symbol: Bool = false) -> NSAttributedString {
      NSAttributedString(
        string: text,
        attributes: [
          .font: symbol ? CaptionLayout.taglineSymbolFont : CaptionLayout.taglineFont,
          .foregroundColor: CaptionLayout.textColor,
        ]
      )
    }
    let tagline = NSMutableAttributedString()
    tagline.append(taglineRun("puff "))
    tagline.append(taglineRun("+", symbol: true))
    tagline.append(taglineRun(" \u{00F7} ", symbol: true))
    tagline.append(taglineRun("pop "))
    tagline.append(taglineRun("+", symbol: true))
    tagline.append(taglineRun(" \u{00F7} ", symbol: true))
    tagline.append(taglineRun("pose"))
    let taglineSize = tagline.size()
    tagline.draw(
      at: CGPoint(
        x: CaptionLayout.taglineCenter.x - taglineSize.width / 2,
        y: CaptionLayout.taglineCenter.y - taglineSize.height / 2
      )
    )

    let dateText = NSAttributedString(
      string: captionDateFormatter.string(from: Date()),
      attributes: [.font: CaptionLayout.dateFont, .foregroundColor: CaptionLayout.textColor]
    )
    let dateSize = dateText.size()
    dateText.draw(
      at: CGPoint(
        x: CaptionLayout.dateCenter.x - dateSize.width / 2,
        y: CaptionLayout.dateCenter.y - dateSize.height / 2
      )
    )

    let credit = NSAttributedString(
      string: "\u{2726} \u{00B7} by lauren & luke \u{00B7} \u{2726}",
      attributes: [.font: CaptionLayout.creditFont, .foregroundColor: CaptionLayout.creditColor]
    )
    let creditSize = credit.size()
    credit.draw(
      at: CGPoint(
        x: CaptionLayout.creditCenter.x - creditSize.width / 2,
        y: CaptionLayout.creditCenter.y - creditSize.height / 2
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
  /// below instead.
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
