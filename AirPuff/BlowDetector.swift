import AVFoundation
import Accelerate
import Foundation

@MainActor
final class BlowDetector: ObservableObject {
  enum PermissionState {
    case undetermined
    case granted
    case denied
  }

  static let calibrationDuration: TimeInterval = 1.5

  @Published private(set) var permissionState: PermissionState = .undetermined
  @Published private(set) var isMonitoring = false
  @Published private(set) var isCalibrating = false
  @Published private(set) var calibrationProgress = 0.0
  @Published private(set) var currentDecibels = -100.0
  @Published private(set) var baselineDecibels = -60.0
  @Published private(set) var strength = 0.0
  @Published private(set) var lastBlowStrength = 0.0
  @Published private(set) var peakDecibels = -100.0
  @Published private(set) var blowCount = 0
  @Published private(set) var completedBlowSequence = 0
  @Published private(set) var isBlowing = false
  @Published var thresholdMargin = 15.0
  @Published var statusMessage = "마이크를 준비하고 있습니다."

  private let audioEngine = AVAudioEngine()
  private var hasInputTap = false
  private var calibrationStartedAt: Date?
  private var calibrationSamples: [Double] = []
  private var candidateStartedAt: Date?
  private var lastAboveThresholdAt: Date?
  private var blowStartedAt: Date?
  private var lastBlowEndedAt = Date.distantPast
  private var eventPeakStrength = 0.0

  // These four values were the whole latency budget when a blow was reported
  // only after it finished. With a live stream the Mac reacts while the player
  // is still blowing, so they only need to be long enough to reject noise.
  private let minimumBlowDuration: TimeInterval = 0.06
  private let releaseDuration: TimeInterval = 0.08
  private let cooldownDuration: TimeInterval = 0.10

  /// Called from the detection state machine itself, not from a view observing
  /// published state, so nothing waits for a SwiftUI update to send.
  var onEvent: ((AirPopMessageType, Double) -> Void)?
  private var lastUpdateSentAt: Date?

  var thresholdDecibels: Double {
    min(-8, baselineDecibels + thresholdMargin)
  }

  var meterLevel: Double {
    min(max((currentDecibels + 80) / 80, 0), 1)
  }

  func requestPermissionAndStart() {
    refreshPermissionState()

    switch permissionState {
    case .granted:
      startMonitoring()
    case .denied:
      statusMessage = "설정에서 마이크 접근을 허용해 주세요."
    case .undetermined:
      AVAudioApplication.requestRecordPermission { [weak self] granted in
        Task { @MainActor in
          guard let self else { return }
          self.permissionState = granted ? .granted : .denied
          if granted {
            self.startMonitoring()
          } else {
            self.statusMessage = "설정에서 마이크 접근을 허용해 주세요."
          }
        }
      }
    }
  }

  func startMonitoring() {
    guard !isMonitoring else { return }
    refreshPermissionState()
    guard permissionState == .granted else {
      requestPermissionAndStart()
      return
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement)
      try session.setPreferredSampleRate(44_100)
      try? session.setPreferredInputNumberOfChannels(1)
      try session.setActive(true)

      let inputNode = audioEngine.inputNode
      let format = inputNode.outputFormat(forBus: 0)
      guard format.channelCount > 0 else {
        throw BlowDetectorError.noAudioInput
      }

      if hasInputTap {
        inputNode.removeTap(onBus: 0)
      }
      inputNode.installTap(
        onBus: 0,
        bufferSize: 1_024,
        format: format
      ) { [weak self] buffer, _ in
        guard let decibels = Self.decibels(from: buffer) else { return }
        Task { @MainActor [weak self] in
          self?.process(decibels: decibels, at: Date())
        }
      }
      hasInputTap = true

      audioEngine.prepare()
      try audioEngine.start()
      isMonitoring = true
      beginCalibration()
    } catch {
      removeInputTapIfNeeded()
      deactivateAudioSession()
      statusMessage = "마이크를 시작하지 못했습니다: \(error.localizedDescription)"
    }
  }

  func stopMonitoring() {
    audioEngine.stop()
    removeInputTapIfNeeded()
    deactivateAudioSession()
    if isBlowing {
      onEvent?(.blowEnd, 0)
    }
    isMonitoring = false
    isCalibrating = false
    isBlowing = false
    strength = 0
    candidateStartedAt = nil
    statusMessage = "측정을 정지했습니다."
  }

  func recalibrate() {
    if !isMonitoring {
      startMonitoring()
      return
    }
    beginCalibration()
  }

  func resetBlowCount() {
    blowCount = 0
    lastBlowStrength = 0
    peakDecibels = -100
  }

  private func refreshPermissionState() {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      permissionState = .granted
    case .denied:
      permissionState = .denied
    case .undetermined:
      permissionState = .undetermined
    @unknown default:
      permissionState = .undetermined
    }
  }

  private func beginCalibration() {
    isCalibrating = true
    calibrationStartedAt = Date()
    calibrationSamples.removeAll(keepingCapacity: true)
    calibrationProgress = 0
    if isBlowing {
      onEvent?(.blowEnd, 0)
    }
    isBlowing = false
    strength = 0
    candidateStartedAt = nil
    lastAboveThresholdAt = nil
    lastUpdateSentAt = nil
    statusMessage = "1.5초 동안 조용히 주변 소음을 측정합니다."
  }

  private func process(decibels rawDecibels: Double, at now: Date) {
    currentDecibels = (currentDecibels * 0.58) + (rawDecibels * 0.42)

    if isCalibrating {
      processCalibrationSample(rawDecibels, at: now)
      return
    }

    processBlowCandidate(decibels: currentDecibels, at: now)
  }

  private func processCalibrationSample(_ decibels: Double, at now: Date) {
    guard let calibrationStartedAt else { return }

    calibrationSamples.append(decibels)
    let elapsed = now.timeIntervalSince(calibrationStartedAt)
    calibrationProgress = min(elapsed / Self.calibrationDuration, 1)

    guard elapsed >= Self.calibrationDuration else { return }

    let sortedSamples = calibrationSamples.sorted()
    if !sortedSamples.isEmpty {
      let percentileIndex = min(
        Int(Double(sortedSamples.count - 1) * 0.6),
        sortedSamples.count - 1
      )
      baselineDecibels = sortedSamples[percentileIndex]
    }

    isCalibrating = false
    calibrationProgress = 1
    statusMessage = "준비 완료. 아래쪽 마이크를 향해 ‘후’ 불어 보세요."
  }

  private func processBlowCandidate(decibels: Double, at now: Date) {
    let isAboveThreshold = decibels >= thresholdDecibels
    let normalizedStrength = normalizedStrength(for: decibels)
    strength = isAboveThreshold ? normalizedStrength : max(strength * 0.55, 0)

    if isAboveThreshold {
      lastAboveThresholdAt = now

      if candidateStartedAt == nil,
        now.timeIntervalSince(lastBlowEndedAt) >= cooldownDuration
      {
        candidateStartedAt = now
      }

      if !isBlowing,
        let candidateStartedAt,
        now.timeIntervalSince(candidateStartedAt) >= minimumBlowDuration
      {
        isBlowing = true
        blowStartedAt = now
        eventPeakStrength = normalizedStrength
        peakDecibels = decibels
        blowCount += 1
        statusMessage = "Blow 감지! 강도 \(Int(normalizedStrength * 100))%"

        lastUpdateSentAt = now
        onEvent?(.blowStart, normalizedStrength)
      } else if isBlowing {
        eventPeakStrength = max(eventPeakStrength, normalizedStrength)
        peakDecibels = max(peakDecibels, decibels)
        statusMessage = "Blow 감지! 강도 \(Int(eventPeakStrength * 100))%"

        // The live value, not the peak: the Mac drives bubble count and speed
        // from what the player is doing right now.
        sendUpdateIfDue(strength: normalizedStrength, at: now)
      }
    } else if isBlowing {
      let silenceDuration = now.timeIntervalSince(lastAboveThresholdAt ?? now)
      if silenceDuration >= releaseDuration {
        finishBlow(at: now)
      }
    } else {
      candidateStartedAt = nil
    }
  }

  /// A blow that lasts is no longer force-ended. The old 1.2 second cap existed
  /// because one blow produced exactly one message; a continuous stream has no
  /// reason to cut the player off mid-breath.
  private func sendUpdateIfDue(strength: Double, at now: Date) {
    if let lastUpdateSentAt,
      now.timeIntervalSince(lastUpdateSentAt) < AirPopLink.targetSendInterval
    {
      return
    }
    lastUpdateSentAt = now
    onEvent?(.blowUpdate, strength)
  }

  private func finishBlow(at now: Date) {
    isBlowing = false
    lastBlowStrength = eventPeakStrength
    completedBlowSequence += 1
    lastBlowEndedAt = now
    candidateStartedAt = nil
    lastAboveThresholdAt = nil
    blowStartedAt = nil
    eventPeakStrength = 0
    lastUpdateSentAt = nil
    statusMessage = "감지 완료. 다시 불어 보세요."

    onEvent?(.blowEnd, 0)
  }

  private func normalizedStrength(for decibels: Double) -> Double {
    let loudReference = -3.0
    let availableRange = max(loudReference - thresholdDecibels, 1)
    return min(max((decibels - thresholdDecibels) / availableRange, 0), 1)
  }

  private func removeInputTapIfNeeded() {
    guard hasInputTap else { return }
    audioEngine.inputNode.removeTap(onBus: 0)
    hasInputTap = false
  }

  private func deactivateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private nonisolated static func decibels(from buffer: AVAudioPCMBuffer) -> Double? {
    guard
      let channelData = buffer.floatChannelData?.pointee,
      buffer.frameLength > 0
    else {
      return nil
    }

    var rootMeanSquare: Float = 0
    vDSP_rmsqv(
      channelData,
      1,
      &rootMeanSquare,
      vDSP_Length(buffer.frameLength)
    )

    guard rootMeanSquare > 0 else { return -100 }
    return max(20 * log10(Double(rootMeanSquare)), -100)
  }
}

private enum BlowDetectorError: LocalizedError {
  case noAudioInput

  var errorDescription: String? {
    "사용 가능한 마이크 입력을 찾지 못했습니다."
  }
}
