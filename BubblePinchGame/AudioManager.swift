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

  /// Decoded once at first use. Building an NSSound from the file on every
  /// pop meant disk read and decode on the main thread, and a hard blow makes
  /// eight bubbles a second for two hands to pop.
  private var prototypes: [String: NSSound] = [:]
  private var activeSounds: [NSSound] = []

  /// A hard blow creates eight bubbles a second and two hands can pop them in
  /// pairs, so overlapping playback is normal. The cap keeps a burst from
  /// accumulating instances faster than they finish.
  private let maximumConcurrentSounds = 16

  func play(_ resourceName: String) {
    guard let sound = instance(of: resourceName) else { return }

    sound.delegate = self
    activeSounds.append(sound)
    sound.play()

    if activeSounds.count > maximumConcurrentSounds {
      activeSounds.removeFirst(activeSounds.count - maximumConcurrentSounds)
    }
  }

  /// One NSSound cannot play twice at once, so each playback gets a copy of
  /// the cached prototype rather than a fresh decode.
  private func instance(of resourceName: String) -> NSSound? {
    if let prototype = prototypes[resourceName] {
      return prototype.copy() as? NSSound
    }

    guard
      let url = Bundle.main.url(forResource: resourceName, withExtension: "wav"),
      let prototype = NSSound(contentsOf: url, byReference: false)
    else {
      return nil
    }

    prototypes[resourceName] = prototype
    return prototype.copy() as? NSSound
  }

  /// Warms the cache so the first pop of a round does not pay for the decode.
  func preload() {
    for name in GameSound.pops + [
      GameSound.bomb,
      GameSound.countdownTick,
      GameSound.roundStart,
      GameSound.roundOver,
    ] {
      _ = instance(of: name)
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
