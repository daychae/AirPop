import AppKit
import Combine
import Foundation

@MainActor
final class GameSession: ObservableObject {
  @Published private(set) var phase: GamePhase = .ready
  @Published private(set) var score = 0
  @Published private(set) var timeRemaining = Int(GameRules.roundDuration)
  @Published private(set) var normalPopped = 0
  @Published private(set) var bombsTriggered = 0
  @Published private(set) var missed = 0
  @Published private(set) var combo = 0
  @Published private(set) var bestCombo = 0
  @Published private(set) var handCount = 0
  @Published private(set) var isNewHighScore = false
  @Published private(set) var resultPhoto: NSImage?

  /// Conditions owned by the camera and the link. The session does not reach
  /// for either of them directly; the view injects what it observes.
  @Published private(set) var isModelReady = false
  @Published private(set) var isPeerConnected = false
  @Published private(set) var isPeerMicReady = false

  let scene = GameScene(size: CGSize(width: 1100, height: 720))

  private(set) var highScore: Int
  private var countdownTask: Task<Void, Never>?
  private var handsMissingSince: Date?
  private var handsFoundSince: Date?

  /// Installed by ContentView because the session owns the score and scene,
  /// while the view owns the camera tracker. The image remains in memory until
  /// the player explicitly chooses where to save it.
  var resultPhotoProvider: ((_ score: Int, _ bestCombo: Int) -> NSImage?)?

  var hasHands: Bool { handCount > 0 }

  /// Both players and both inputs have to be ready. Starting a round with one
  /// side missing leaves that player watching a game they cannot affect.
  var canStart: Bool {
    hasHands && isModelReady && isPeerConnected && isPeerMicReady
  }

  func setModelReady(_ ready: Bool) {
    guard isModelReady != ready else { return }
    isModelReady = ready
  }

  func setPeerMicReady(_ ready: Bool) {
    guard isPeerMicReady != ready else { return }
    isPeerMicReady = ready
  }

  /// Losing the phone mid-round is reported separately from losing a hand:
  /// the two need different instructions on screen.
  func setPeerConnected(_ connected: Bool) {
    guard isPeerConnected != connected else { return }
    isPeerConnected = connected
    scene.setCooperative(connected)

    if !connected {
      isPeerMicReady = false
      if phase == .playing {
        phase = .pausedPeerLost
        scene.setRoundPaused(true)
      }
    } else if phase == .pausedPeerLost {
      phase = hasHands ? .playing : .pausedHandLost
      scene.setRoundPaused(!hasHands)
    }
  }

  init() {
    highScore = UserDefaults.standard.integer(forKey: "AirPop.highScore")
    connectScene()
    scene.prepareForReady()
  }

  func handleHandPoses(
    _ poses: [HandPose],
    viewPoints: [Int: CGPoint]
  ) {
    handCount = poses.count
    scene.updateHandPoses(poses, viewPoints: viewPoints)

    if poses.isEmpty {
      handsFoundSince = nil
      if phase == .playing {
        if handsMissingSince == nil {
          handsMissingSince = Date()
        }
        if let handsMissingSince,
          Date().timeIntervalSince(handsMissingSince) >= 1.5
        {
          self.handsMissingSince = nil
          phase = .pausedHandLost
          scene.setRoundPaused(true)
        }
      }
    } else {
      handsMissingSince = nil
      if phase == .pausedHandLost {
        if handsFoundSince == nil {
          handsFoundSince = Date()
        }
        if let handsFoundSince,
          Date().timeIntervalSince(handsFoundSince) >= 0.8
        {
          self.handsFoundSince = nil
          phase = .playing
          scene.setRoundPaused(false)
        }
      }
    }
  }

  /// Hand tracking flickers frame to frame -- a single missed frame during
  /// the 3-2-1 countdown was enough to send the player back to the ready
  /// screen, which felt like the hand tracking itself kept breaking.
  /// `beginCountdown` only re-checks the conditions that don't jitter once
  /// it's running; a genuine hand loss once play actually starts is still
  /// caught by `handleHandPoses`'s existing pause logic below.
  private var canStartIgnoringHands: Bool {
    isModelReady && isPeerConnected && isPeerMicReady
  }

  func beginCountdown() {
    guard phase == .ready, canStart else { return }
    countdownTask?.cancel()

    countdownTask = Task { @MainActor [weak self] in
      guard let self else { return }

      for value in [3, 2, 1] {
        guard !Task.isCancelled, self.canStartIgnoringHands else {
          self.phase = .ready
          return
        }
        self.phase = .countdown(value)
        AudioManager.shared.play(GameSound.countdownTick)
        try? await Task.sleep(for: .seconds(1))
      }

      guard !Task.isCancelled, self.canStartIgnoringHands else {
        self.phase = .ready
        return
      }

      self.resetScore()
      self.phase = .playing
      self.scene.startRound()
      AudioManager.shared.play(GameSound.roundStart)
    }
  }

  func returnToReady() {
    countdownTask?.cancel()
    phase = .ready
    resetScore()
    scene.prepareForReady()
  }

  /// One blow, one immediate bubble. Everything after that comes from the rate
  /// the strength implies, not from message arrivals.
  func handleBlowStarted(strength: Double) {
    scene.handleBlowStarted(strength: strength)
  }

  func updateBlowState(isBlowing: Bool, strength: Double) {
    scene.updateBlowState(isBlowing: isBlowing, strength: strength)
  }

  private func connectScene() {
    scene.onNormalPopped = { [weak self] in
      guard let self else { return }
      self.normalPopped += 1
      self.combo += 1
      self.bestCombo = max(self.bestCombo, self.combo)
      self.updateScore()
    }
    scene.onBombTriggered = { [weak self] in
      guard let self else { return }
      self.bombsTriggered += 1
      self.combo = 0
      self.updateScore()
    }
    scene.onNormalMissed = { [weak self] in
      self?.missed += 1
    }
    scene.onTimeChanged = { [weak self] remaining in
      self?.timeRemaining = remaining
    }
    scene.onRoundEnded = { [weak self] in
      self?.finishRound()
    }
  }

  private func updateScore() {
    score = GameRules.score(
      normalPopped: normalPopped,
      bombsTriggered: bombsTriggered
    )
  }

  private func resetScore() {
    score = 0
    timeRemaining = Int(GameRules.roundDuration)
    normalPopped = 0
    bombsTriggered = 0
    missed = 0
    combo = 0
    bestCombo = 0
    isNewHighScore = false
    resultPhoto = nil
    handsMissingSince = nil
    handsFoundSince = nil
  }

  private func finishRound() {
    guard phase == .playing || phase.isPaused else { return }
    resultPhoto = resultPhotoProvider?(score, bestCombo)
    phase = .result
    AudioManager.shared.play(GameSound.roundOver)
    isNewHighScore = score > highScore
    if isNewHighScore {
      highScore = score
      UserDefaults.standard.set(score, forKey: "AirPop.highScore")
    }
  }
}
