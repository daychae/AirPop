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

  private let minimumGestureConfidence = 0.65

  /// Pinch entry is instant; release takes two frames. Asymmetric on purpose:
  /// a late pop feels broken, while a pinch that flickers off for one frame in
  /// the middle of a gesture pops a second bubble.
  private let requiredReleaseFrameCount = 2

  /// Hysteresis on the thumb-index gap, as a fraction of hand scale. Entering
  /// below 0.45 and only releasing above 0.60 means the ambiguous band in
  /// between holds whatever the hand was already doing, instead of flickering
  /// across a single boundary.
  /// Adjustable at run time from the diagnostics panel, because the value that
  /// feels right depends on how far the player stands from the camera.
  @Published private(set) var pinchEnterRatio: CGFloat = 0.50
  private var pinchExitRatio: CGFloat { pinchEnterRatio + 0.18 }

  /// Fingers this close are a pinch whatever the classifier says. It is the
  /// backstop for a bad camera angle, not the normal path.
  /// Geometric backstop. It matters when the operator widens the threshold past
  /// where the classifier was trained, and when a prediction hiccups.
  private var geometricPinchRatio: CGFloat { pinchEnterRatio * 0.90 }

  /// Only there to reject a closed fist, where the gap between thumb and index
  /// stops meaning anything. A deep pinch curls the index finger and shortens
  /// this measurably, so the floor sits well below a relaxed hand's value.
  private let minimumIndexExtension: CGFloat = 0.45
  /// Lowered from 0.35: at exhibition distance and lighting, requiring five
  /// joints to each clear 0.35 dropped hands that were plainly visible.
  private let minimumJointConfidence: VNConfidence = 0.30
  /// In units of image height, like every other distance here.
  private let maximumTrackMatchDistance: CGFloat = 0.35
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

  /// Vision reports 0...1 on both axes, but the frame is not square: at
  /// 1280x720 the same physical gap measures 1.78x larger vertically than
  /// horizontally. Since a pinch gap runs mostly vertical while palm width runs
  /// mostly horizontal, leaving this uncorrected inflated every pinch ratio by
  /// up to that factor, which is why fingers had to nearly touch to register.
  private var captureAspectRatio: CGFloat = 16.0 / 9.0

  private var configured = false
  private var visionIsBusy = false
  private var nextTrackID = 0
  private var handTracks: [Int: HandTrack] = [:]

  private struct DetectedHand {
    let thumbTip: CGPoint
    let indexTip: CGPoint
    let pinchPoint: CGPoint
    let pinchRatio: CGFloat
    let indexExtension: CGFloat
    let prediction: GesturePrediction
  }

  private struct HandTrack {
    let id: Int
    var pinchPoint: CGPoint
    var isPinching: Bool
    var releaseFrameCount: Int
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

    if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format)
      if dimensions.height > 0 {
        captureAspectRatio =
          CGFloat(dimensions.width) / CGFloat(dimensions.height)
      }
    }

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
    // Only the three joints the pinch is measured from are required. Demanding
    // all five, as before, threw away hands that were plainly visible whenever
    // one knuckle happened to be occluded.
    guard
      let thumb = try? observation.recognizedPoint(.thumbTip),
      let index = try? observation.recognizedPoint(.indexTip),
      let indexMCP = try? observation.recognizedPoint(.indexMCP),
      thumb.confidence >= minimumJointConfidence,
      index.confidence >= minimumJointConfidence,
      indexMCP.confidence >= minimumJointConfidence
    else {
      return nil
    }

    let thumbRaw = CGPoint(x: thumb.location.x, y: thumb.location.y)
    let indexRaw = CGPoint(x: index.location.x, y: index.location.y)
    let indexMCPRaw = CGPoint(x: indexMCP.location.x, y: indexMCP.location.y)

    guard
      let handScale = handScale(
        from: observation,
        indexMCP: indexMCPRaw
      )
    else {
      return nil
    }

    let pinchRatio = distance(thumbRaw, indexRaw) / handScale
    let indexExtension = distance(indexRaw, indexMCPRaw) / handScale
    let fingertipConfidence = Double(min(thumb.confidence, index.confidence))

    // The thumb knuckle is only used for a classifier feature, so a missing one
    // is worth estimating rather than dropping the whole hand for.
    let thumbExtension: CGFloat
    if let thumbMP = try? observation.recognizedPoint(.thumbMP),
      thumbMP.confidence >= minimumJointConfidence
    {
      thumbExtension =
        distance(thumbRaw, CGPoint(x: thumbMP.location.x, y: thumbMP.location.y))
        / handScale
    } else {
      thumbExtension = 0.75
    }

    let prediction = gestureClassifier.predict(
      metrics: HandMetrics(
        pinchRatio: Double(pinchRatio),
        indexExtension: Double(indexExtension),
        thumbExtension: Double(thumbExtension),
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
      indexExtension: indexExtension,
      prediction: prediction
    )
  }

  /// Every measurement here is a ratio against hand size, so the reference
  /// length decides whether a pinch reads as a pinch.
  ///
  /// Palm width alone collapses when the hand tilts towards the camera, which
  /// inflates every ratio and makes a real pinch look like an open hand at the
  /// exact angle players use when reaching for a bubble. Wrist to middle
  /// knuckle barely changes under that rotation, so the larger of the two is
  /// the more honest scale.
  private func handScale(
    from observation: VNHumanHandPoseObservation,
    indexMCP: CGPoint
  ) -> CGFloat? {
    var candidates: [CGFloat] = []

    if let littleMCP = try? observation.recognizedPoint(.littleMCP),
      littleMCP.confidence >= minimumJointConfidence
    {
      candidates.append(
        distance(indexMCP, CGPoint(x: littleMCP.location.x, y: littleMCP.location.y))
      )
    }

    if let wrist = try? observation.recognizedPoint(.wrist),
      let middleMCP = try? observation.recognizedPoint(.middleMCP),
      wrist.confidence >= minimumJointConfidence,
      middleMCP.confidence >= minimumJointConfidence
    {
      let palmLength = distance(
        CGPoint(x: wrist.location.x, y: wrist.location.y),
        CGPoint(x: middleMCP.location.x, y: middleMCP.location.y)
      )
      // Palm length runs longer than palm width on a real hand; scaled so the
      // two references produce comparable ratios.
      candidates.append(palmLength * 0.80)
    }

    guard let scale = candidates.max(), scale > 0.001 else { return nil }
    return scale
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
      let wasPinching = previousTrack?.isPinching ?? false
      let previousSmoothed = previousTrack?.smoothedPoint

      let (isPinching, releaseFrameCount) = resolvePinch(
        detection,
        wasPinching: wasPinching,
        releaseFrameCount: previousTrack?.releaseFrameCount ?? 0
      )

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
        isPinching: isPinching,
        releaseFrameCount: releaseFrameCount,
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

  /// Hysteresis, not a single boundary.
  ///
  /// Driving the state from the classifier's label alone meant a hand hovering
  /// near the decision point flipped every frame, and any band the classifier
  /// was unsure about froze the hand in whatever state it started in. Entry and
  /// release now have separate thresholds, and the gap between them is what
  /// absorbs the jitter.
  private func resolvePinch(
    _ detection: DetectedHand,
    wasPinching: Bool,
    releaseFrameCount: Int
  ) -> (isPinching: Bool, releaseFrameCount: Int) {
    let prediction = detection.prediction
    let isConfident = prediction.confidence >= minimumGestureConfidence
    let looksLikeHand = detection.indexExtension >= minimumIndexExtension

    guard wasPinching else {
      guard looksLikeHand, detection.pinchRatio <= pinchEnterRatio else {
        return (false, 0)
      }
      // The classifier decides open against pinch inside the range it was
      // trained on; the threshold above is a hard gate the operator can widen
      // on site, and the geometric backstop covers the widened band.
      let classifierAgrees = prediction.gesture == .pinch && isConfident
      let geometryAgrees = detection.pinchRatio <= geometricPinchRatio
      return (classifierAgrees || geometryAgrees, 0)
    }

    // A hand that has curled out of view should release rather than stay
    // latched, so a failed shape check counts towards release too.
    let wantsRelease =
      !looksLikeHand
      || detection.pinchRatio >= pinchExitRatio
      || (prediction.gesture == .open && isConfident
        && detection.pinchRatio > pinchEnterRatio)

    guard wantsRelease else { return (true, 0) }

    let count = releaseFrameCount + 1
    return count >= requiredReleaseFrameCount ? (false, 0) : (true, count)
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

  /// Distance in units of image height. Scaling x by the aspect ratio undoes
  /// Vision's per-axis normalization so a measurement means the same thing
  /// whichever way the hand is turned.
  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot((a.x - b.x) * captureAspectRatio, a.y - b.y)
  }

  /// Nudges the pinch threshold while the app runs. The useful range is roughly
  /// a 2cm to 5cm thumb-index gap on an adult hand.
  func adjustPinchEnterRatio(by delta: CGFloat) {
    let updated = min(max(pinchEnterRatio + delta, 0.20), 0.85)
    guard updated != pinchEnterRatio else { return }
    DispatchQueue.main.async { [weak self] in
      self?.pinchEnterRatio = updated
    }
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
