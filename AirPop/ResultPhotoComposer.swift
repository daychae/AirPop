import AppKit
import CoreGraphics

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
/// can't be edited in place -- pixel-level inpainting against the busy
/// bubble background left a visible seam. Instead this draws an opaque
/// frosted plate over that exact footprint (measured directly off the
/// baked text, top-left origin, then converted to bottom-up CG coordinates
/// the same way `FrameLayout.windowRect` is) and renders a live caption
/// with the real capture date on top.
private enum CaptionLayout {
  static let plateRect = CGRect(x: 255, y: 54, width: 690, height: 151)
  static let cornerRadius: CGFloat = 22
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
      context.draw(overlayImage, in: FrameLayout.windowRect)
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

    drawCaption(context: context)

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
  }

  private static let frameCGImage: CGImage? = {
    guard let image = NSImage(named: "PhotoFrameCool") else { return nil }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }()

  private static let captionDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy.MM.dd"
    return formatter
  }()

  /// Covers the frame art's baked-in caption with an opaque frosted plate
  /// (see `CaptionLayout`), then draws a live caption -- the real capture
  /// date, computed when the photo is taken -- on top.
  private static func drawCaption(context: CGContext) {
    let plate = CaptionLayout.plateRect
    let platePath = CGPath(
      roundedRect: plate,
      cornerWidth: CaptionLayout.cornerRadius,
      cornerHeight: CaptionLayout.cornerRadius,
      transform: nil
    )

    context.saveGState()
    context.setShadow(
      offset: CGSize(width: 0, height: -2),
      blur: 10,
      color: NSColor.black.withAlphaComponent(0.12).cgColor
    )
    context.addPath(platePath)
    context.setFillColor(NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.99, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(platePath)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    context.setLineWidth(1.5)
    context.strokePath()
    context.restoreGState()

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let title = NSAttributedString(
      string: "AirPop & AirPuff",
      attributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .bold),
        .foregroundColor: CaptionLayout.titleColor,
      ]
    )
    let subtitle = NSAttributedString(
      string: "by L & L | \(captionDateFormatter.string(from: Date()))",
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .medium),
        .foregroundColor: CaptionLayout.subtitleColor,
        .kern: 2.5,
      ]
    )

    let titleSize = title.size()
    let subtitleSize = subtitle.size()
    let gap: CGFloat = 10
    let blockHeight = titleSize.height + gap + subtitleSize.height
    let subtitleBottomY = plate.midY - blockHeight / 2
    let titleBottomY = subtitleBottomY + subtitleSize.height + gap

    title.draw(at: CGPoint(x: plate.midX - titleSize.width / 2, y: titleBottomY))
    subtitle.draw(at: CGPoint(x: plate.midX - subtitleSize.width / 2, y: subtitleBottomY))

    NSGraphicsContext.restoreGraphicsState()
  }

  private static func drawMirroredAspectFill(
    _ image: CGImage,
    in bounds: CGRect,
    context: CGContext
  ) {
    let sourceSize = CGSize(width: image.width, height: image.height)
    let scale = max(
      bounds.width / sourceSize.width,
      bounds.height / sourceSize.height
    )
    let drawSize = CGSize(
      width: sourceSize.width * scale,
      height: sourceSize.height * scale
    )
    let drawRect = CGRect(
      x: (bounds.width - drawSize.width) * 0.5,
      y: (bounds.height - drawSize.height) * 0.5,
      width: drawSize.width,
      height: drawSize.height
    )

    context.saveGState()
    context.translateBy(x: bounds.origin.x, y: bounds.origin.y)
    context.translateBy(x: bounds.width, y: 0)
    context.scaleBy(x: -1, y: 1)
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
