import AppKit
import CoreGraphics

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
}

/// Position/type spec for the caption, measured directly off the baked
/// title/"by L & L" text in PhotoFrameCoolBase.png (top-left origin, then
/// converted to bottom-up CG coordinates the same way
/// `FrameLayout.windowRect` is) plus the date/divider spec from
/// iOS_macOS_app_frames_updated/README.txt.
private enum CaptionLayout {
  static let titleFont = NSFont.systemFont(ofSize: 34, weight: .bold)
  static let titleColor = NSColor(
    calibratedRed: CGFloat(0x3A) / 255, green: CGFloat(0x4A) / 255,
    blue: CGFloat(0xA8) / 255, alpha: 1)
  /// Center of the "AirPop & AirPuff" title, at x600,y1039 (top-left
  /// origin) -- the midpoint of its measured bounding box.
  static let titleCenter = CGPoint(x: 600, y: canvasHeight - 1039)

  /// "by L & L", the date, and the divider between them all share one
  /// row/style: IBM Plex Mono Regular, 27px, 0.24em letter-spacing (per the
  /// README's date spec), sitting on the same baseline band as "by L & L"
  /// in the baked art (y 1106...1131, center 1118.5, matching the README's
  /// date baseline band of y 1099...1135, center 1117).
  static let fontSize: CGFloat = 27
  static let kerning: CGFloat = fontSize * 0.24
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

    if let baseCGImage {
      context.draw(baseCGImage, in: CGRect(origin: .zero, size: outputSize))
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

    // Bubbles that spill onto the photo's edges, with a transparent center,
    // drawn after the photo so they sit on top of it near the border.
    if let topCGImage {
      context.draw(topCGImage, in: CGRect(origin: .zero, size: outputSize))
    }

    drawCaption(context: context)

    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: outputSize)
  }

  private static let baseCGImage: CGImage? = loadNamedImage("PhotoFrameCoolBase")
  private static let topCGImage: CGImage? = loadNamedImage("PhotoFrameCoolTop")

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
      string: "AirPop & AirPuff",
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

    let rowFont = NSFont.monospacedSystemFont(ofSize: CaptionLayout.fontSize, weight: .regular)
    let byLine = NSAttributedString(
      string: "by L & L",
      attributes: [
        .font: rowFont,
        .foregroundColor: CaptionLayout.rowColor,
        .kern: CaptionLayout.kerning,
      ]
    )
    let dateText = NSAttributedString(
      string: captionDateFormatter.string(from: Date()),
      attributes: [
        // The spec calls for IBM Plex Mono Regular; substituting the system
        // monospaced font until that font file is bundled into the project.
        .font: rowFont,
        .foregroundColor: CaptionLayout.rowColor,
        .kern: CaptionLayout.kerning,
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
