import SwiftUI

struct HandOverlayView: View {
    let poses: [HandPose]
    let coordinateMapper: CameraCoordinateMapper

    var body: some View {
        GeometryReader { _ in
            ForEach(poses) { pose in
                if let thumb = coordinateMapper.viewPoint(
                    fromCaptureDevicePoint: pose.thumbTip
                ),
                let index = coordinateMapper.viewPoint(
                    fromCaptureDevicePoint: pose.indexTip
                ),
                let pinch = coordinateMapper.viewPoint(
                    fromCaptureDevicePoint: pose.pinchPoint
                ) {

                    Path { path in
                        path.move(to: thumb)
                        path.addLine(to: index)
                    }
                    .stroke(
                        pose.isPinching ? Color.green : Color.white.opacity(0.72),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )

                    jointDot(at: thumb, color: .pink)
                    jointDot(at: index, color: .cyan)

                    Circle()
                        .fill(pose.isPinching ? Color.green : Color.white)
                        .frame(width: pose.isPinching ? 22 : 14,
                               height: pose.isPinching ? 22 : 14)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.45), lineWidth: 1)
                        )
                        .position(pinch)
                        .animation(.easeOut(duration: 0.08), value: pose.isPinching)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func jointDot(at point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
            .position(point)
    }
}
