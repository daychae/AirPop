@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import Vision

final class CameraHandTracker: NSObject, ObservableObject {
  @Published private(set) var poses: [HandPose] = []
  @Published private(set) var statusText = "Starting camera…"
  @Published private(set) var permissionDenied = false

  let session = AVCaptureSession()

  /// The geometry fallback keeps the game playable without the compiled model,
  /// so readiness no longer gates play on Core ML alone.
  var isMLReady: Bool { true }
  var classifierName: String {
    gestureClassifier.isReady
      ? "Vision + Core ML"
      : "Vision + joint geometry (모델 없음)"
  }

  /// Hands Vision found but the confidence gate rejected. Published so the
  /// threshold below can be tuned against what the venue actually produces
  /// instead of by guesswork.
  @Published private(set) var rejectedHandCount = 0

  // Core ML predictions must remain stable for two frames before changing state.
  private let minimumGestureConfidence = 0.65
  private let requiredStableFrameCount = 2
  /// Lowered from 0.35: at exhibition distance and lighting, requiring five
  /// joints to each clear 0.35 dropped hands that were plainly visible.
  private let minimumJointConfidence: VNConfidence = 0.30
  private let maximumTrackMatchDistance: CGFloat = 0.25
  /// Roughly a quarter second at 30fps. A hand that passes behind the other
  /// player briefly keeps its id and its pinch state, instead of coming back as
  /// a new track whose first stable pinch pops a second bubble.
  private let maximumMissedFrameCount = 8

  private let captureQueue = DispatchQueue(label: "bubble.camera.capture")
  private let visionQueue = DispatchQueue(label: "bubble.camera.vision")
  private let videoOutput = AVCaptureVideoDataOutput()
  private let gestureClassifier = HandGestureClassifier()
  private let handPoseRequest: VNDetectHumanHandPoseRequest = {
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 4
    return request
  }()

  private var configured = false
  private var visionIsBusy = false
  private var nextTrackID = 0
  private var handTracks: [Int: HandTrack] = [:]

  private struct DetectedHand {
    let thumbTip: CGPoint
    let indexTip: CGPoint
    let pinchPoint: CGPoint
    let pinchRatio: CGFloat
    let prediction: GesturePrediction
  }

  private struct HandTrack {
    let id: Int
    var pinchPoint: CGPoint
    var stableGesture: HandGesture
    var candidateGesture: HandGesture
    var candidateFrameCount: Int
    var missedFrameCount: Int

    /// Exponentially smoothed aim. Raw Vision output jitters enough that an
    /// unsmoothed pointer visibly shakes on a bubble.
    var smoothedPoint: CGPoint
    /// Held while the fingers are closing. Pinching moves both fingertips, so
    /// the midpoint travels several bubble radii during the gesture and would
    /// otherwise pop whatever the hand drifted onto.
    var lockedPoint: CGPoint?
    var previousPinchRatio: CGFloat?
  }

  private let smoothingFactor: CGFloat = 0.38
  /// Below this the hand is closing enough to be aiming at something.
  private let pinchIntentRatio: CGFloat = 0.62
  /// Above this the hand has clearly reopened, so aim is free again.
  private let pinchReleaseRatio: CGFloat = 0.72

  override init() {
    super.init()
    requestCameraAccessAndStart()
  }

  deinit {
    session.stopRunning()
  }

  private func requestCameraAccessAndStart() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureAndStart()

    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        guard let self else { return }
        if granted {
          self.configureAndStart()
        } else {
          DispatchQueue.main.async {
            self.permissionDenied = true
            self.statusText = "Camera permission is required."
          }
        }
      }

    case .denied, .restricted:
      DispatchQueue.main.async {
        self.permissionDenied = true
        self.statusText = "Camera permission is required."
      }

    @unknown default:
      DispatchQueue.main.async {
        self.permissionDenied = true
        self.statusText = "Camera access is unavailable."
      }
    }
  }

  private func configureAndStart() {
    captureQueue.async { [weak self] in
      guard let self, !self.configured else { return }

      self.session.beginConfiguration()
      // 720p rather than whatever .high resolves to. Vision runs on every
      // frame alongside SpriteKit and the link, and the extra pixels of a 1080p
      // feed buy no accuracy at exhibition distance.
      if self.session.canSetSessionPreset(.hd1280x720) {
        self.session.sessionPreset = .hd1280x720
      } else {
        self.session.sessionPreset = .high
      }

      var shouldStart = false
      defer {
        // AVCaptureSession requires configuration to be committed
        // before startRunning().
        self.session.commitConfiguration()

        if shouldStart {
          self.configured = true
          self.session.startRunning()

          DispatchQueue.main.async {
            self.statusText = "Show up to four hands to the camera."
          }
        }
      }

      guard let camera = AVCaptureDevice.default(for: .video) else {
        DispatchQueue.main.async {
          self.statusText = "No camera was found."
        }
        return
      }

      do {
        let input = try AVCaptureDeviceInput(device: camera)

        guard self.session.canAddInput(input) else {
          DispatchQueue.main.async {
            self.statusText = "Could not attach the camera."
          }
          return
        }
        self.session.addInput(input)

        self.videoOutput.alwaysDiscardsLateVideoFrames = true
        self.videoOutput.videoSettings = [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_32BGRA
        ]
        self.videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)

        guard self.session.canAddOutput(self.videoOutput) else {
          DispatchQueue.main.async {
            self.statusText = "Could not create the video stream."
          }
          return
        }
        self.session.addOutput(self.videoOutput)
        shouldStart = true
      } catch {
        DispatchQueue.main.async {
          self.statusText = "Camera error: \(error.localizedDescription)"
        }
      }
    }
  }

  private func clearPoses(
    message: String = "Show up to four hands to the camera.",
    resetTracking: Bool = false
  ) {
    if resetTracking {
      handTracks.removeAll()
    } else {
      ageUnmatchedTracks(matching: [])
    }

    DispatchQueue.main.async { [weak self] in
      self?.poses = []
      self?.statusText = message
    }
  }

  private func process(_ sampleBuffer: CMSampleBuffer) {
    // Keep only one Vision request in flight. This prevents latency building up.
    guard !visionIsBusy else { return }
    visionIsBusy = true
    defer { visionIsBusy = false }

    let handler = VNImageRequestHandler(
      cmSampleBuffer: sampleBuffer,
      orientation: .up,
      options: [:]
    )

    do {
      try handler.perform([handPoseRequest])

      let detectedHands = (handPoseRequest.results ?? []).compactMap {
        detectedHand(from: $0)
      }

      let rejected = (handPoseRequest.results ?? []).count - detectedHands.count
      DispatchQueue.main.async { [weak self] in
        // Assigning unconditionally would publish on every frame and re-run the
        // whole view body for a number that is almost always zero.
        guard let self, self.rejectedHandCount != rejected else { return }
        self.rejectedHandCount = rejected
      }

      guard !detectedHands.isEmpty else {
        clearPoses()
        return
      }

      let newPoses = updateTracks(with: detectedHands)

      DispatchQueue.main.async { [weak self] in
        self?.poses = newPoses
        self?.statusText = self?.statusText(for: newPoses) ?? ""
      }
    } catch {
      clearPoses(
        message: "Vision error: \(error.localizedDescription)",
        resetTracking: true
      )
    }
  }

  private func detectedHand(
    from observation: VNHumanHandPoseObservation
  ) -> DetectedHand? {
    guard
      let thumb = try? observation.recognizedPoint(.thumbTip),
      let thumbMP = try? observation.recognizedPoint(.thumbMP),
      let index = try? observation.recognizedPoint(.indexTip),
      let indexMCP = try? observation.recognizedPoint(.indexMCP),
      let littleMCP = try? observation.recognizedPoint(.littleMCP),
      thumb.confidence >= minimumJointConfidence,
      thumbMP.confidence >= minimumJointConfidence,
      index.confidence >= minimumJointConfidence,
      indexMCP.confidence >= minimumJointConfidence,
      littleMCP.confidence >= minimumJointConfidence
    else {
      return nil
    }

    let thumbRaw = CGPoint(x: thumb.location.x, y: thumb.location.y)
    let thumbMPRaw = CGPoint(x: thumbMP.location.x, y: thumbMP.location.y)
    let indexRaw = CGPoint(x: index.location.x, y: index.location.y)
    let indexMCPRaw = CGPoint(x: indexMCP.location.x, y: indexMCP.location.y)
    let littleMCPRaw = CGPoint(x: littleMCP.location.x, y: littleMCP.location.y)
    let palmWidth = max(distance(indexMCPRaw, littleMCPRaw), 0.001)
    let pinchRatio = distance(thumbRaw, indexRaw) / palmWidth
    let fingertipConfidence = Double(min(thumb.confidence, index.confidence))

    let prediction = gestureClassifier.predict(
      metrics: HandMetrics(
        pinchRatio: Double(pinchRatio),
        indexExtension: Double(distance(indexRaw, indexMCPRaw) / palmWidth),
        thumbExtension: Double(distance(thumbRaw, thumbMPRaw) / palmWidth),
        fingertipConfidence: fingertipConfidence
      ))

    // Vision uses a bottom-left origin. Keep x unmirrored and convert y
    // to the capture-device top-left coordinate space expected by the
    // preview layer. It applies the actual crop and mirroring later.
    let thumbUI = captureDevicePoint(thumbRaw)
    let indexUI = captureDevicePoint(indexRaw)

    return DetectedHand(
      thumbTip: thumbUI,
      indexTip: indexUI,
      pinchPoint: CGPoint(
        x: (thumbUI.x + indexUI.x) * 0.5,
        y: (thumbUI.y + indexUI.y) * 0.5
      ),
      pinchRatio: pinchRatio,
      prediction: prediction
    )
  }

  private func updateTracks(with detections: [DetectedHand]) -> [HandPose] {
    let existingTrackIDs = Array(handTracks.keys)
    var possibleMatches: [(distance: CGFloat, detection: Int, track: Int)] = []

    for (detectionIndex, detection) in detections.enumerated() {
      for trackID in existingTrackIDs {
        guard let track = handTracks[trackID] else { continue }
        possibleMatches.append(
          (
            distance: distance(detection.pinchPoint, track.pinchPoint),
            detection: detectionIndex,
            track: trackID
          ))
      }
    }

    possibleMatches.sort { $0.distance < $1.distance }

    var trackForDetection: [Int: Int] = [:]
    var matchedTrackIDs: Set<Int> = []

    for match in possibleMatches where match.distance <= maximumTrackMatchDistance {
      guard trackForDetection[match.detection] == nil,
        !matchedTrackIDs.contains(match.track)
      else {
        continue
      }

      trackForDetection[match.detection] = match.track
      matchedTrackIDs.insert(match.track)
    }

    ageUnmatchedTracks(matching: matchedTrackIDs)

    return detections.enumerated().map { detectionIndex, detection in
      let trackID: Int
      if let matchedID = trackForDetection[detectionIndex] {
        trackID = matchedID
      } else {
        trackID = nextTrackID
        nextTrackID += 1
      }

      let previousTrack = handTracks[trackID]
      let wasPinching = previousTrack?.stableGesture == .pinch
      var stableGesture = previousTrack?.stableGesture ?? .open
      var candidateGesture = previousTrack?.candidateGesture ?? .unknown
      var candidateFrameCount = previousTrack?.candidateFrameCount ?? 0
      let previousSmoothed = previousTrack?.smoothedPoint

      let prediction = detection.prediction
      if prediction.confidence >= minimumGestureConfidence,
        prediction.gesture != .unknown
      {
        if prediction.gesture == stableGesture {
          candidateGesture = .unknown
          candidateFrameCount = 0
        } else if prediction.gesture == candidateGesture {
          candidateFrameCount += 1
        } else {
          candidateGesture = prediction.gesture
          candidateFrameCount = 1
        }

        if candidateFrameCount >= requiredStableFrameCount {
          stableGesture = prediction.gesture
          candidateGesture = .unknown
          candidateFrameCount = 0
        }
      } else {
        candidateGesture = .unknown
        candidateFrameCount = 0
      }

      let isPinching = stableGesture == .pinch

      let smoothed = smooth(detection.pinchPoint, from: previousSmoothed)
      var lockedPoint = previousTrack?.lockedPoint
      let previousRatio = previousTrack?.previousPinchRatio

      // Lock on the position the hand held *before* the fingers started
      // closing, not on where they end up once closed.
      let crossedIntent =
        detection.pinchRatio < pinchIntentRatio
        && (previousRatio ?? detection.pinchRatio) >= pinchIntentRatio
      if lockedPoint == nil, crossedIntent || isPinching {
        lockedPoint = previousSmoothed ?? smoothed
      }
      if detection.pinchRatio > pinchReleaseRatio {
        lockedPoint = nil
      }

      handTracks[trackID] = HandTrack(
        id: trackID,
        pinchPoint: detection.pinchPoint,
        stableGesture: stableGesture,
        candidateGesture: candidateGesture,
        candidateFrameCount: candidateFrameCount,
        missedFrameCount: 0,
        smoothedPoint: smoothed,
        lockedPoint: lockedPoint,
        previousPinchRatio: detection.pinchRatio
      )

      return HandPose(
        id: trackID,
        thumbTip: detection.thumbTip,
        indexTip: detection.indexTip,
        pointer: lockedPoint ?? smoothed,
        pinchRatio: detection.pinchRatio,
        isPinching: isPinching,
        pinchBegan: isPinching && !wasPinching
      )
    }
  }

  private func ageUnmatchedTracks(matching matchedTrackIDs: Set<Int>) {
    for trackID in Array(handTracks.keys) where !matchedTrackIDs.contains(trackID) {
      guard var track = handTracks[trackID] else { continue }
      track.missedFrameCount += 1

      if track.missedFrameCount > maximumMissedFrameCount {
        handTracks.removeValue(forKey: trackID)
      } else {
        handTracks[trackID] = track
      }
    }
  }

  private func statusText(for poses: [HandPose]) -> String {
    let handLabel = poses.count == 1 ? "1 hand" : "\(poses.count) hands"
    let pinchCount = poses.lazy.filter(\.isPinching).count

    if pinchCount > 0 {
      return "\(handLabel) · \(pinchCount) PINCH"
    }

    return "\(handLabel) detected"
  }

  private func smooth(_ point: CGPoint, from previous: CGPoint?) -> CGPoint {
    guard let previous else { return point }
    return CGPoint(
      x: previous.x + (point.x - previous.x) * smoothingFactor,
      y: previous.y + (point.y - previous.y) * smoothingFactor
    )
  }

  private func captureDevicePoint(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: point.x,
      y: 1.0 - point.y
    )
  }

  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
  }
}

extension CameraHandTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    process(sampleBuffer)
  }
}
