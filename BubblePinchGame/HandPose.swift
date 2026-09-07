import CoreGraphics

/// Coordinates are normalized to 0...1 in the unmirrored capture-device space.
/// Origin is top-left so AVCaptureVideoPreviewLayer can apply its exact crop,
/// orientation, and mirroring when mapping points into the preview.
struct HandPose: Equatable, Identifiable {
    let id: Int
    let thumbTip: CGPoint
    let indexTip: CGPoint
    /// Raw midpoint between the fingertips. Used for drawing.
    let pinchPoint: CGPoint

    /// Where this hand is aiming. Smoothed, and held still while the fingers
    /// close, so the act of pinching does not drag the aim off the target.
    let pointer: CGPoint

    let pinchRatio: CGFloat
    let isPinching: Bool
    let pinchBegan: Bool
}
