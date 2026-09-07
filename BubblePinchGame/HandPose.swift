import CoreGraphics

/// Coordinates are normalized to 0...1 in the unmirrored capture-device space.
/// Origin is top-left so AVCaptureVideoPreviewLayer can apply its exact crop,
/// orientation, and mirroring when mapping points into the preview.
struct HandPose: Equatable, Identifiable {
    let id: Int
    let thumbTip: CGPoint
    let indexTip: CGPoint
    let pinchPoint: CGPoint
    let pinchRatio: CGFloat
    let isPinching: Bool
    let pinchBegan: Bool
}
