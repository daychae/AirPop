import AppKit
import CoreGraphics
import CoreImage

/// Layout for the "Cool" PhotoFrameCool asset (Assets.xcassets/PhotoFrameCool):
/// a fixed 1200x1200 square with a rounded photo window cut into it, plus a
/// caption baked into the artwork itself. See
/// iOS_macOS_app_frames/README.txt for the source spec (window at x140,y140,
/// 920x790, corner radius 24, given in top-left-origin image coordinates).
private enum FrameLayout {
  static let canvasSize = CGSize(width: 1200, height: 1200)
  static let cornerRadius: CGFloat = 24

  /// The photo window, converted from the asset's top-left-origin spec into
  /// CGContext's bottom-up coordinate space: y = canvasHeight - top - height.
  static let windowRect = CGRect(x: 140, y: 270, width: 920, height: 790)
}

/// The frame art's caption ("AirPop & AirPuff / by Lauren & Luke |
/// 2026.09.12") is baked into its pixels with a fixed name and date, so it
/// can't be edited in place. Rather than covering that footprint with a
/// flat plate (which reads as an obvious box sitting on top of the art),
/// this blurs just that region of the frame's OWN background (never the
/// photo -- the footprint sits below the photo window, so the two never
/// overlap) so the old text dissolves into a soft, on-brand blur with no
/// hard edge, the same way a soft-focus vignette would, and draws a live
/// caption with the real capture date directly on top of it.
private enum CaptionLayout {
  /// Footprint measured directly off the baked title/subtitle text (top-left
  /// origin), converted to bottom-up CG coordinates the same way
  /// `FrameLayout.windowRect` is, with margin for the blur to fall off into.
  static let softenRect = CGRect(x: 220, y: 45, width: 760, height: 165)
  static let backgroundBlurRadius: CGFloat = 30
  static let maskBlurRadius: CGFloat = 26
  /// Sampled from the baked title/subtitle strokes in PhotoFrameCool.png.
  static let titleColor = NSColor(
    calibratedRed: CGFloat(0x3A) / 255, green: CGFloat(0x4A) / 255,
    blue: CGFloat(0xA8) / 255, alpha: 1)
  static let subtitleColor = NSColor(
    calibratedRed: CGFloat(0x3F) / 255, green: CGFloat(0x4A) / 255,
    blue: CGFloat(0x86) / 255, alpha: 1)
}

enum ResultPhotoComposer {
  static func make(
    cameraImage: CGImage,
    overlayImage: CGImage?,
    canvasSize: CGSize,
    score: Int,
    bestCombo: Int
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

    let windowPath = CGPath(
      roundedRect: FrameLayout.windowRect,
      cornerWidth: FrameLayout.cornerRadius,
      cornerHeight: FrameLayout.cornerRadius,
      transform: nil
    )

    context.saveGState()
    context.addPath(windowPath)
    context.clip()

    drawMirroredAspectFill(
      cameraImage,
      in: FrameLayout.windowRect,
      context: context
    )

    context.setFillColor(NSColor.black.withAlphaComponent(0.16).cgColor)
    context.fill(FrameLayout.windowRect)

    if let overlayImage {
      // Aspect-fill like the camera layer, not a plain stretch-to-rect draw:
      // the SpriteKit scene's aspect ratio (scene.size, i.e. `canvasSize`)
      // matches the on-screen game window, not the frame's 920x790 window,
      // so drawing it straight into `windowRect` squashed it vertically.
      drawAspectFill(overlayImage, in: FrameLayout.windowRect, context: context)
    }

    drawScoreBadge(score: score, bestCombo: bestCombo, window: FrameLayout.windowRect, context: context)

    context.restoreGState()

    // The frame's bubbles, the caption baked into the artwork, and the
    // border are all one piece of pre-rendered art with a transparent
    // cutout matching `windowRect` above, drawn on top so it always sits
    // above the photo regardless of what the player pointed the camera at.
    if let frameCGImage {
      context.draw(frameCGImage, in: CGRect(origin: .zero, size: outputSize))
    }

    softenCaptionFootprint(context: context, canvasSize: outputSize)
    drawCaption(context: context)

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
  }

  private static let frameCGImage: CGImage? = {
    guard let image = NSImage(named: "PhotoFrameCool") else { return nil }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }()

  private static let ciContext = CIContext(options: nil)

  /// A blurred copy of just the frame ART (never the photo, which the frame
  /// art is later drawn over) so the old caption dissolves into an
  /// unreadable, on-brand blur. Computed once and cached: it's the same
  /// every time regardless of what photo is being composed.
  private static let blurredFrameCGImage: CGImage? = {
    guard let frameCGImage, let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
    let ciImage = CIImage(cgImage: frameCGImage)
    blur.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
    blur.setValue(CaptionLayout.backgroundBlurRadius, forKey: kCIInputRadiusKey)
    guard let output = blur.outputImage?.cropped(to: ciImage.extent) else { return nil }
    return ciContext.createCGImage(output, from: ciImage.extent)
  }()

  /// A soft-edged grayscale mask the size of the whole canvas: white (fully
  /// visible) over `CaptionLayout.softenRect`, black everywhere else, then
  /// blurred so the boundary fades rather than cutting a hard rectangle.
  /// Used with `CGContext.clip(to:mask:)` to blend the blurred frame art
  /// back in only over the caption footprint.
  private static func featheredCaptionMask(canvasSize: CGSize) -> CGImage? {
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
    maskContext.fill(CaptionLayout.softenRect)
    guard let rawMask = maskContext.makeImage() else { return nil }

    let ciMask = CIImage(cgImage: rawMask)
    guard let blur = CIFilter(name: "CIGaussianBlur") else { return rawMask }
    blur.setValue(ciMask.clampedToExtent(), forKey: kCIInputImageKey)
    blur.setValue(CaptionLayout.maskBlurRadius, forKey: kCIInputRadiusKey)
    guard
      let output = blur.outputImage?.cropped(to: ciMask.extent),
      let blurredMask = ciContext.createCGImage(output, from: ciMask.extent)
    else { return rawMask }
    return blurredMask
  }

  private static let captionDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy.MM.dd"
    return formatter
  }()

  /// Blends the blurred frame art back in over just the caption footprint,
  /// through a feathered mask, so the old baked-in text dissolves without a
  /// visible seam or box.
  private static func softenCaptionFootprint(context: CGContext, canvasSize: CGSize) {
    guard
      let blurredFrameCGImage,
      let mask = featheredCaptionMask(canvasSize: canvasSize)
    else { return }
    context.saveGState()
    context.clip(to: CGRect(origin: .zero, size: canvasSize), mask: mask)
    context.draw(blurredFrameCGImage, in: CGRect(origin: .zero, size: canvasSize))
    context.restoreGState()
  }

  /// Draws a live caption -- the real capture date, computed when the photo
  /// is taken -- directly over the softened footprint. No plate/box: the
  /// blur in `softenCaptionFootprint` already makes the text legible against
  /// the frame's own background.
  private static func drawCaption(context: CGContext) {
    let region = CaptionLayout.softenRect

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.white.withAlphaComponent(0.7)
    shadow.shadowBlurRadius = 4
    shadow.shadowOffset = .zero

    let title = NSAttributedString(
      string: "AirPop & AirPuff",
      attributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .bold),
        .foregroundColor: CaptionLayout.titleColor,
        .shadow: shadow,
      ]
    )
    let subtitle = NSAttributedString(
      string: "by L & L | \(captionDateFormatter.string(from: Date()))",
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .medium),
        .foregroundColor: CaptionLayout.subtitleColor,
        .kern: 0.8,
        .shadow: shadow,
      ]
    )

    let titleSize = title.size()
    let subtitleSize = subtitle.size()
    let gap: CGFloat = 10
    let blockHeight = titleSize.height + gap + subtitleSize.height
    let subtitleBottomY = region.midY - blockHeight / 2
    let titleBottomY = subtitleBottomY + subtitleSize.height + gap

    title.draw(at: CGPoint(x: region.midX - titleSize.width / 2, y: titleBottomY))
    subtitle.draw(at: CGPoint(x: region.midX - subtitleSize.width / 2, y: subtitleBottomY))

    NSGraphicsContext.restoreGraphicsState()
  }

  private static func aspectFillRect(source: CGSize, in bounds: CGRect) -> CGRect {
    let scale = max(
      bounds.width / source.width,
      bounds.height / source.height
    )
    let drawSize = CGSize(width: source.width * scale, height: source.height * scale)
    return CGRect(
      x: (bounds.width - drawSize.width) * 0.5,
      y: (bounds.height - drawSize.height) * 0.5,
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

  /// A small frosted pill in the photo window's top-left corner, since the
  /// frame's own caption area (baked into the artwork, below the window)
  /// has no room left for the live score/combo.
  private static func drawScoreBadge(
    score: Int,
    bestCombo: Int,
    window: CGRect,
    context: CGContext
  ) {
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = CGSize(width: 0, height: -1)

    let text = NSAttributedString(
      string: "SCORE \(score)   BEST COMBO \(bestCombo)",
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
        .foregroundColor: NSColor.white,
        .shadow: shadow,
      ]
    )
    let textSize = text.size()
    let horizontalPadding: CGFloat = 16
    let verticalPadding: CGFloat = 10
    let margin: CGFloat = 20
    let pillSize = CGSize(
      width: textSize.width + horizontalPadding * 2,
      height: textSize.height + verticalPadding * 2
    )
    let pillRect = CGRect(
      x: window.minX + margin,
      y: window.maxY - margin - pillSize.height,
      width: pillSize.width,
      height: pillSize.height
    )

    NSColor.black.withAlphaComponent(0.5).setFill()
    NSBezierPath(roundedRect: pillRect, xRadius: pillSize.height / 2, yRadius: pillSize.height / 2)
      .fill()

    text.draw(
      at: CGPoint(
        x: pillRect.minX + horizontalPadding,
        y: pillRect.minY + verticalPadding
      )
    )

    NSGraphicsContext.restoreGraphicsState()
  }
}
