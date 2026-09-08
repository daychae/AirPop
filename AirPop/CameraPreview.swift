@preconcurrency import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class CameraCoordinateMapper: ObservableObject {
    fileprivate let previewLayer = AVCaptureVideoPreviewLayer()

    /// Converts normalized, unmirrored top-left camera coordinates into the
    /// preview's view coordinates, including aspect-fill crop and mirroring.
    func viewPoint(fromCaptureDevicePoint point: CGPoint) -> CGPoint? {
        guard previewLayer.bounds.width > 0, previewLayer.bounds.height > 0 else {
            return nil
        }

        return previewLayer.layerPointConverted(fromCaptureDevicePoint: point)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let coordinateMapper: CameraCoordinateMapper

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(previewLayer: coordinateMapper.previewLayer)
        view.setSession(session)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.setSession(session)
        }
    }
}

final class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private var sessionDidStartObserver: NSObjectProtocol?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let sessionDidStartObserver {
            NotificationCenter.default.removeObserver(sessionDidStartObserver)
        }
    }

    func setSession(_ session: AVCaptureSession) {
        if let sessionDidStartObserver {
            NotificationCenter.default.removeObserver(sessionDidStartObserver)
        }

        previewLayer.session = session
        sessionDidStartObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.configureMirroring()
        }

        configureMirroring()
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        configureMirroring()
    }

    private func configureMirroring() {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else {
            return
        }

        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}
