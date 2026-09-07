import AppKit
import Foundation

/// Plays the short game sounds.
///
/// `NSSound` rather than SpriteKit actions so a sound is never tied to the
/// lifetime of the node that triggered it: a bubble is removed from the scene
/// in the same frame it pops.
@MainActor
final class AudioManager: NSObject, NSSoundDelegate {
  static let shared = AudioManager()

  private var activeSounds: [NSSound] = []

  /// A hard blow creates eight bubbles a second and two hands can pop them in
  /// pairs, so overlapping playback is normal. The cap keeps a burst from
  /// accumulating instances faster than they finish.
  private let maximumConcurrentSounds = 16

  func play(_ resourceName: String) {
    guard
      let url = Bundle.main.url(forResource: resourceName, withExtension: "wav"),
      let sound = NSSound(contentsOf: url, byReference: false)
    else {
      return
    }

    sound.delegate = self
    activeSounds.append(sound)
    sound.play()

    if activeSounds.count > maximumConcurrentSounds {
      activeSounds.removeFirst(activeSounds.count - maximumConcurrentSounds)
    }
  }

  nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
    Task { @MainActor [weak self] in
      self?.activeSounds.removeAll { $0 === sound }
    }
  }
}

enum GameSound {
  static let pops = ["bubble_pop_01", "bubble_pop_02", "bubble_pop_03"]
  static let bomb = "bomb_explosion"
  static let countdownTick = "countdown_tick"
  static let roundStart = "game_start"
  static let roundOver = "game_over"
}
