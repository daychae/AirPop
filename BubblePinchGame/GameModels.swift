import CoreGraphics
import Foundation

enum GamePhase: Equatable {
    case ready
    case countdown(Int)
    case playing
    case pausedHandLost
    /// The phone dropped out. Kept separate from a lost hand because the two
    /// need different instructions on screen.
    case pausedPeerLost
    case result

    var showsHUD: Bool {
        switch self {
        case .playing, .pausedHandLost, .pausedPeerLost:
            return true
        case .ready, .countdown, .result:
            return false
        }
    }

    var isPaused: Bool {
        switch self {
        case .pausedHandLost, .pausedPeerLost: return true
        default: return false
        }
    }

    var wire: AirPopGamePhase {
        switch self {
        case .ready: return .ready
        case .countdown: return .countdown
        case .playing: return .playing
        case .pausedHandLost: return .pausedHandsLost
        case .pausedPeerLost: return .pausedPeerLost
        case .result: return .result
        }
    }

    var countdownValue: Int? {
        if case .countdown(let value) = self { return value }
        return nil
    }
}

struct Difficulty {
    let spawnInterval: TimeInterval
    let speedRange: ClosedRange<CGFloat>
    let bombProbability: Double
}

enum GameRules {
    static let roundDuration: TimeInterval = 30
    static let maximumBubbles = 10
    static let maximumBombs = 2

    static func difficulty(at elapsed: TimeInterval) -> Difficulty {
        switch elapsed {
        case 0..<5:
            return Difficulty(
                spawnInterval: 0.90,
                speedRange: 0.13...0.17,
                bombProbability: 0
            )
        case 5..<15:
            return Difficulty(
                spawnInterval: 0.75,
                speedRange: 0.16...0.21,
                bombProbability: 0.10
            )
        case 15..<23:
            return Difficulty(
                spawnInterval: 0.65,
                speedRange: 0.20...0.25,
                bombProbability: 0.15
            )
        default:
            return Difficulty(
                spawnInterval: 0.55,
                speedRange: 0.24...0.30,
                bombProbability: 0.20
            )
        }
    }

    static func score(normalPopped: Int, bombsTriggered: Int) -> Int {
        max(0, normalPopped - bombsTriggered * 3)
    }
}

/// Maps blow strength to how fast bubbles appear and how fast they rise.
///
/// The stops come from the tuning table in the modification plan and are
/// interpolated between, so the difference between a soft and a hard blow is a
/// gradient rather than three steps. They are starting values: the venue's
/// room noise and microphone distance decide the final numbers.
enum BlowSpawnRules {
    /// (strength, bubbles per second, screen heights per second)
    private static let stops: [(strength: Double, rate: Double, speed: Double)] = [
        (0.00, 0.0, 0.00),
        (0.20, 2.0, 0.12),
        (0.55, 5.0, 0.20),
        (1.00, 8.0, 0.30),
    ]

    static func spawnRate(for strength: Double) -> Double {
        interpolate(strength) { $0.rate }
    }

    static func riseSpeed(for strength: Double) -> Double {
        interpolate(strength) { $0.speed }
    }

    private static func interpolate(
        _ strength: Double,
        _ value: ((strength: Double, rate: Double, speed: Double)) -> Double
    ) -> Double {
        let clamped = min(max(strength, 0), 1)

        guard let upperIndex = stops.firstIndex(where: { $0.strength >= clamped }) else {
            return value(stops[stops.count - 1])
        }
        guard upperIndex > 0 else { return value(stops[0]) }

        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let span = upper.strength - lower.strength
        guard span > 0 else { return value(upper) }

        let progress = (clamped - lower.strength) / span
        return value(lower) + (value(upper) - value(lower)) * progress
    }
}
