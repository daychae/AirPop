import AppKit
import CoreGraphics
import CoreImage

/// Layout for the wide frame (`PhotoFrameWide` in Assets.xcassets): a fixed
/// 1920x1200 canvas, single layer. Unlike the old square PhotoFrameCool
/// (base+top, because the top layer's bubbles spilled onto the photo's
/// edges), nothing in this design overlaps the oval photo window -- the
/// foreground bubbles and the whole caption (logo, tagline, divider,
/// "by lauren & luke") all sit safely below it -- so one image is enough.
/// The oval's bounds and the date's position/size below were measured
/// directly off that image's alpha channel and text pixels (see the
/// scratch analysis from the "Wide Frame" handoff), not off a written spec.
private enum FrameLayout {
  static let canvasSize = CGSize(width: 1920, height: 1200)

  /// The oval photo window, already converted from the asset's top-left
  /// pixel measurement into CGContext's bottom-up coordinate space:
  /// y = canvasHeight - top - height.
  static let windowRect = CGRect(x: 552, y: 516, width: 815, height: 433)

  /// The oval's own edge in the art is already soft (a faint glow ring),
  /// so this only needs to smooth the hand-off between that and the photo,
  /// not do the heavy lifting the old square frame's feather did.
  static let windowEdgeFeather: CGFloat = 10
}

/// The live date is the only part of the caption drawn fresh -- the logo,
/// tagline, divider, and "by lauren & luke" are all baked into
/// PhotoFrameWide itself since they never change. The baked art carries a
/// "YYYY.MM.DD" placeholder at this position; drawing the real date in the
/// same monospaced font, size, and color exactly covers it, since both
/// strings are 10 characters in the same digits/dots pattern.
private enum CaptionLayout {
  static let dateFont =
    NSFont(name: "GoogleSansCode-Medium", size: 34)
    ?? NSFont.monospacedSystemFont(ofSize: 34, weight: .medium)
  /// Sampled from the baked "YYYY.MM.DD" placeholder in PhotoFrameWide.png.
  static let dateColor = NSColor(
    calibratedRed: CGFloat(0x26) / 255, green: CGFloat(0x9A) / 255,
    blue: CGFloat(0xFF) / 255, alpha: 1)
  /// Center of the date text, measured off the baked placeholder's pixel
  /// bounds (top-left y 1110...1135, x 856...1063), converted to bottom-up.
  static let dateCenter = CGPoint(x: 960, y: 77)
  /// A generous box around the baked "YYYY.MM.DD" placeholder (bottom-up).
  /// Drawing the live date directly on top of the placeholder at the same
  /// font/size/position looked right in theory -- both strings are 10
  /// characters in the same digits/dots pattern -- but any sub-pixel
  /// mismatch between the two left a visible ghosted double-exposure of
  /// glyph edges. Replacing this box with a clean background fill once (see
  /// `ResultPhotoComposer.suppressDatePlaceholder`) erases the placeholder
  /// outright, so the live date goes on top of a clean surface instead of
  /// trying to land exactly on top of another string.
  static let datePlaceholderBlurRect = CGRect(x: 800, y: 40, width: 340, height: 80)
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

    drawDate(context: context)

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
  }

  private static let baseCGImage: CGImage? = {
    guard let raw = loadNamedImage("PhotoFrameWide") else { return nil }
    return suppressDatePlaceholder(in: raw)
  }()
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

  /// Replaces `CaptionLayout.datePlaceholderBlurRect` in the base image once
  /// (cached in `baseCGImage`, not redone per capture) with a clean fill so
  /// the baked "YYYY.MM.DD" placeholder is gone before the live date is ever
  /// drawn on top of it.
  ///
  /// An earlier version blurred the placeholder in place instead of
  /// replacing it, which softened the glyphs but mixed their blue ink into
  /// the surrounding pixels -- leaving a faint blue glow around the live
  /// date. Sampling clean background color from just outside the glyphs and
  /// painting a gradient between those two samples removes the blue
  /// entirely; a light blur of a small margin around the patch (of the new,
  /// already-clean pixels only) then hides the patch's own rectangular edge.
  private static func suppressDatePlaceholder(in image: CGImage) -> CGImage {
    let canvasSize = FrameLayout.canvasSize
    guard
      let context = CGContext(
        data: nil,
        width: Int(canvasSize.width),
        height: Int(canvasSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return image }
    context.draw(image, in: CGRect(origin: .zero, size: canvasSize))

    let blurRect = CaptionLayout.datePlaceholderBlurRect
    let pixelRect = CGRect(
      x: blurRect.minX,
      y: canvasSize.height - blurRect.maxY,
      width: blurRect.width,
      height: blurRect.height
    )

    guard let wholeBeforePatch = context.makeImage() else { return image }
    let rep = NSBitmapImageRep(cgImage: wholeBeforePatch)
    guard
      let leftColor = rep.colorAt(x: Int(pixelRect.minX), y: Int(pixelRect.midY)),
      let rightColor = rep.colorAt(x: Int(pixelRect.maxX), y: Int(pixelRect.midY)),
      let patch = gradientPatch(from: leftColor, to: rightColor, size: blurRect.size)
    else { return image }

    context.draw(patch, in: blurRect)

    let featherMargin: CGFloat = 6
    let featherRect = blurRect.insetBy(dx: -featherMargin, dy: -featherMargin)
    let featherPixelRect = CGRect(
      x: featherRect.minX,
      y: canvasSize.height - featherRect.maxY,
      width: featherRect.width,
      height: featherRect.height
    )
    if
      let wholeAfterPatch = context.makeImage(),
      let regionToFeather = wholeAfterPatch.cropping(to: featherPixelRect)
    {
      let ciRegion = CIImage(cgImage: regionToFeather)
      if let blurFilter = CIFilter(name: "CIGaussianBlur") {
        blurFilter.setValue(ciRegion.clampedToExtent(), forKey: kCIInputImageKey)
        blurFilter.setValue(4.0, forKey: kCIInputRadiusKey)
        if
          let output = blurFilter.outputImage?.cropped(to: ciRegion.extent),
          let blurredRegion = ciContext.createCGImage(output, from: ciRegion.extent)
        {
          context.draw(blurredRegion, in: featherRect)
        }
      }
    }

    return context.makeImage() ?? image
  }

  /// A `size`-sized horizontal linear gradient between two flat colors, used
  /// to replace the baked date placeholder with a patch that carries none of
  /// its color.
  private static func gradientPatch(from: NSColor, to: NSColor, size: CGSize) -> CGImage? {
    guard
      let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let fromRGB = from.usingColorSpace(.deviceRGB),
      let toRGB = to.usingColorSpace(.deviceRGB),
      let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [fromRGB.cgColor, toRGB.cgColor] as CFArray,
        locations: [0, 1]
      )
    else { return nil }
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: 0, y: size.height / 2),
      end: CGPoint(x: size.width, y: size.height / 2),
      options: []
    )
    return context.makeImage()
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

  /// Draws only the live capture date, centered exactly where the baked
  /// "YYYY.MM.DD" placeholder in PhotoFrameWide.png sits -- see
  /// `CaptionLayout` for why nothing else needs to be drawn here.
  private static func drawDate(context: CGContext) {
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let dateText = NSAttributedString(
      string: captionDateFormatter.string(from: Date()),
      attributes: [
        .font: CaptionLayout.dateFont,
        .foregroundColor: CaptionLayout.dateColor,
      ]
    )
    let dateSize = dateText.size()
    dateText.draw(
      at: CGPoint(
        x: CaptionLayout.dateCenter.x - dateSize.width / 2,
        y: CaptionLayout.dateCenter.y - dateSize.height / 2
      )
    )

    NSGraphicsContext.restoreGraphicsState()
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
