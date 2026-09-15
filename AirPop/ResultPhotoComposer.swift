import AppKit
import CoreGraphics
import CoreImage

/// Layout for the square frame (`PhotoFrameSquare` in Assets.xcassets): a
/// fixed 1200x1200 canvas, single layer. The logo, tagline, and
/// "by lauren & luke" credit are baked into the art (composited from the
/// designer's separate background + caption-sprite files), so only the
/// live date is drawn fresh, replacing a baked "YYYY.MM.DD" placeholder --
/// same technique as the once-used wide frame.
private enum FrameLayout {
  static let canvasSize = CGSize(width: 1200, height: 1200)

  /// A hard geometric cut, unlike the art's own baked window whose edge
  /// is already soft -- needs more blur to keep the hand-off from
  /// reading as jagged.
  static let windowEdgeFeather: CGFloat = 16
}

/// Two window shapes, both kept -- both were liked, and neither is baked
/// into the art (the photo window is always a code-side clip), so
/// there's no extra asset cost to keeping both. Rather than picking one
/// internally, `ResultPhotoComposer.make` takes the shape as a parameter
/// so the view can render one of each and let the player choose. Both
/// were sized by eye to fill the art's bright "clearing" while still
/// clearing the baked tagline above (bottom sits at top-left y~195) and
/// the credit/date block below (top starts at top-left y~1044).
enum WindowShape: CaseIterable {
  case circle
  case roundedRect

  var rect: CGRect {
    switch self {
    case .circle: return CGRect(x: 190, y: 170, width: 820, height: 820)
    case .roundedRect: return CGRect(x: 150, y: 181, width: 900, height: 799)
    }
  }

  private var cornerRadius: CGFloat { 40 }

  func addPath(to context: CGContext) {
    switch self {
    case .circle:
      context.addEllipse(in: rect)
    case .roundedRect:
      context.addPath(
        CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    }
  }
}

/// The live date is the only part of the caption drawn fresh -- see
/// `FrameLayout` for why. The baked art carries a "YYYY.MM.DD" placeholder
/// at this position; drawing the real date in the same monospaced font,
/// size, and color exactly covers it.
private enum CaptionLayout {
  /// Handjet is a seven-segment-display-style face -- the faint "ghost"
  /// segments behind each lit digit are intentional to the font, not a
  /// rendering glitch, and read well as a photo-booth-style date stamp.
  /// 32pt matches the baked placeholder's own rendered height (~23px).
  static let dateFont =
    NSFont(name: "Handjet-Medium", size: 32)
    ?? NSFont.monospacedSystemFont(ofSize: 32, weight: .medium)
  static let dateColor = NSColor.white
  /// Matches the slight shadow baked behind the rest of the caption (see
  /// the credit/logo sprite) -- enough to lift white text off the frame's
  /// own pale background without reading as a heavy drop shadow.
  static let dateShadowColor = NSColor.black.withAlphaComponent(0.3)
  static let dateShadowBlur: CGFloat = 5
  static let dateCenter = CGPoint(x: 600, y: 65)
  /// A generous box around the baked "YYYY.MM.DD" placeholder (bottom-up).
  static let datePlaceholderBlurRect = CGRect(x: 520, y: 48, width: 160, height: 33)
}

enum ResultPhotoComposer {
  static func make(
    cameraImage: CGImage,
    overlayImage: CGImage?,
    canvasSize: CGSize,
    windowShape: WindowShape
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

    let windowRect = windowShape.rect

    context.saveGState()
    if let mask = featheredWindowMask(canvasSize: outputSize, shape: windowShape) {
      context.clip(to: CGRect(origin: .zero, size: outputSize), mask: mask)
    } else {
      windowShape.addPath(to: context)
      context.clip()
    }

    // Scaled to match the *canvas's* height, not the window's -- the photo
    // is a backdrop the frame sits on top of, not an image tailored to
    // the window's own box, so the window (whatever shape/size it is)
    // reads as a viewport onto one consistent backdrop rather than each
    // capture rescaling the photo to exactly fill wherever the window
    // happens to be.
    let photoBackdropRect = CGRect(origin: .zero, size: outputSize)

    drawMirroredAspectFill(
      cameraImage,
      in: photoBackdropRect,
      context: context
    )

    // Lightened from 0.16 -- a dim real-world photo read noticeably heavy
    // at the darker tint.
    context.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    context.fill(windowRect)

    // A real room behind the subject often has its own hard edges (a wall/
    // ceiling line, a phone in hand) that read as a distracting straight
    // border cutting across the round window -- nothing to composite away
    // since it's live camera content, not frame art. Darkening toward the
    // window's edge fades those peripheral details out instead, the same
    // way a portrait vignette pulls focus to the center.
    drawEdgeVignette(in: windowRect, context: context)

    if let overlayImage {
      // Aspect-fill like the camera layer (and into the same backdrop
      // rect, so bubbles stay aligned to where they were actually popped
      // relative to the photo): the SpriteKit scene's aspect ratio
      // (scene.size, i.e. `canvasSize`) matches the on-screen game
      // window, not this frame's canvas, so drawing it at any other
      // scale would shift bubbles away from the photo content they
      // belong over. The bubbles it draws are the only game content that
      // belongs in the photo -- no score/combo text.
      drawAspectFill(overlayImage, in: photoBackdropRect, context: context)
    }

    context.restoreGState()

    drawDate(context: context)

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
  }

  private static let baseCGImage: CGImage? = {
    guard let raw = loadNamedImage("PhotoFrameSquare") else { return nil }
    return suppressDatePlaceholder(in: raw)
  }()
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
  private static func featheredWindowMask(canvasSize: CGSize, shape: WindowShape) -> CGImage? {
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
    shape.addPath(to: maskContext)
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
  /// drawn on top of it. Samples clean background color from just outside
  /// the placeholder glyphs and paints a gradient between those two
  /// samples, rather than blurring the placeholder in place, which would
  /// mix its ink into the surrounding pixels and leave a visible tint.
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
  /// "YYYY.MM.DD" placeholder in PhotoFrameSquare.png sits -- see
  /// `CaptionLayout` for why nothing else needs to be drawn here.
  private static func drawDate(context: CGContext) {
    context.saveGState()
    context.setShadow(
      offset: .zero, blur: CaptionLayout.dateShadowBlur,
      color: CaptionLayout.dateShadowColor.cgColor
    )

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
    context.restoreGState()
  }

  /// A radial darkening from the window's center out to its edge/corners,
  /// on top of the flat dim tint above. Clear in the middle (where a
  /// subject's face or hands usually land) and noticeably darker at the
  /// rim, so peripheral background detail -- and any hard edges in it --
  /// fades rather than competing with the frame.
  private static func drawEdgeVignette(in rect: CGRect, context: CGContext) {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let halfWidth = rect.width / 2
    let halfHeight = rect.height / 2
    let innerRadius = min(halfWidth, halfHeight) * 0.4
    let outerRadius = (halfWidth * halfWidth + halfHeight * halfHeight).squareRoot()

    guard
      let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
          NSColor.black.withAlphaComponent(0).cgColor,
          NSColor.black.withAlphaComponent(0.42).cgColor,
        ] as CFArray,
        locations: [0, 1]
      )
    else { return }

    // Already inside the window's own clip (circle or rounded rect) from
    // the caller's scope -- no need to clip again to `rect` itself.
    context.drawRadialGradient(
      gradient,
      startCenter: center, startRadius: innerRadius,
      endCenter: center, endRadius: outerRadius,
      options: [.drawsAfterEndLocation]
    )
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
