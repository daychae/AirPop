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
                let pointer = coordinateMapper.viewPoint(
                    fromCaptureDevicePoint: pose.pointer
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

                    // A ring, not a dot: the aim is held still while the
                    // fingers close, so it has to read as its own thing rather
                    // than as a point that failed to follow the hand.
                    Circle()
                        .fill(
                            pose.isPinching
                                ? Color.green.opacity(0.42)
                                : Color.white.opacity(0.16)
                        )
                        .overlay(
                            Circle().stroke(
                                pose.isPinching ? Color.green : Color.white.opacity(0.85),
                                lineWidth: pose.isPinching ? 3.5 : 2
                            )
                        )
                        .frame(width: pose.isPinching ? 34 : 24,
                               height: pose.isPinching ? 34 : 24)
                        .position(pointer)
                        .animation(.easeOut(duration: 0.08), value: pose.isPinching)

                    Text("\(pose.id)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .position(x: pointer.x, y: pointer.y - 26)
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
