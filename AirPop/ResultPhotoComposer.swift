import AppKit
import CoreGraphics

/// Lavender ("Pop Lilac"), AirPop's own color in the bubble design system,
/// used for the score line baked into the exported result photo.
private enum Brand {
  static let lavender = NSColor(
    calibratedRed: CGFloat(0xBF) / 255, green: CGFloat(0xA6) / 255,
    blue: CGFloat(0xFA) / 255, alpha: 1)
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

    let width = 1_280
    let aspectRatio = canvasSize.width / canvasSize.height
    let height = max(720, Int((CGFloat(width) / aspectRatio).rounded()))
    let outputSize = CGSize(width: width, height: height)

    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }

    drawMirroredAspectFill(
      cameraImage,
      in: CGRect(origin: .zero, size: outputSize),
      context: context
    )

    context.setFillColor(NSColor.black.withAlphaComponent(0.16).cgColor)
    context.fill(CGRect(origin: .zero, size: outputSize))

    if let overlayImage {
      context.draw(overlayImage, in: CGRect(origin: .zero, size: outputSize))
    }

    drawFooter(
      score: score,
      bestCombo: bestCombo,
      size: outputSize,
      context: context
    )

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
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
    context.translateBy(x: bounds.width, y: 0)
    context.scaleBy(x: -1, y: 1)
    context.interpolationQuality = .high
    context.draw(image, in: drawRect)
    context.restoreGState()
  }

  private static func drawFooter(
    score: Int,
    bestCombo: Int,
    size: CGSize,
    context: CGContext
  ) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
      colorsSpace: colorSpace,
      colors: [
        NSColor.clear.cgColor,
        NSColor.black.withAlphaComponent(0.82).cgColor,
      ] as CFArray,
      locations: [0, 1]
    ) {
      context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size.height * 0.42),
        end: CGPoint(x: 0, y: 0),
        options: []
      )
    }

    // A soft white rim, matching the frosted-glass border used on the
    // bubbles and on the Figma photo-card treatment.
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.82).cgColor)
    context.setLineWidth(max(2, size.width * 0.002))
    context.stroke(
      CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
    )

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = CGSize(width: 0, height: -2)

    let margin = size.width * 0.045
    let title = NSAttributedString(
      string: "AIR POP",
      attributes: [
        .font: NSFont.systemFont(ofSize: size.height * 0.060, weight: .black),
        .foregroundColor: NSColor.white,
        .shadow: shadow,
      ]
    )
    title.draw(at: CGPoint(x: margin, y: size.height * 0.055))

    let result = NSAttributedString(
      string: "SCORE  \(score)     BEST COMBO  \(bestCombo)",
      attributes: [
        .font: NSFont.monospacedSystemFont(
          ofSize: size.height * 0.030,
          weight: .bold
        ),
        .foregroundColor: Brand.lavender,
        .shadow: shadow,
      ]
    )
    let resultSize = result.size()
    result.draw(
      at: CGPoint(
        x: size.width - margin - resultSize.width,
        y: size.height * 0.065
      )
    )

    NSGraphicsContext.restoreGraphicsState()
  }
}
