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

  let scene = GameScene(size: CGSize(width: 1100, height: 720))

  private(set) var highScore: Int
  private var countdownTask: Task<Void, Never>?
  private var handsMissingSince: Date?
  private var handsFoundSince: Date?

  var hasHands: Bool { handCount > 0 }

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

  func beginCountdown() {
    guard phase == .ready, hasHands else { return }
    countdownTask?.cancel()

    countdownTask = Task { @MainActor [weak self] in
      guard let self else { return }

      for value in [3, 2, 1] {
        guard !Task.isCancelled, self.hasHands else {
          self.phase = .ready
          return
        }
        self.phase = .countdown(value)
        try? await Task.sleep(for: .seconds(1))
      }

      guard !Task.isCancelled, self.hasHands else {
        self.phase = .ready
        return
      }

      self.resetScore()
      self.phase = .playing
      self.scene.startRound()
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

  /// With a phone attached the blow drives creation; without one the timed
  /// difficulty curve keeps a solo round playable.
  func setCooperative(_ cooperative: Bool) {
    scene.setCooperative(cooperative)
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
    handsMissingSince = nil
    handsFoundSince = nil
  }

  private func finishRound() {
    guard phase == .playing || phase == .pausedHandLost else { return }
    phase = .result
    isNewHighScore = score > highScore
    if isNewHighScore {
      highScore = score
      UserDefaults.standard.set(score, forKey: "AirPop.highScore")
    }
  }
}
