import CoreGraphics
import Foundation

enum GamePhase: Equatable {
    case ready
    case countdown(Int)
    case playing
    case pausedHandLost
    case result

    var showsHUD: Bool {
        switch self {
        case .playing, .pausedHandLost:
            return true
        case .ready, .countdown, .result:
            return false
        }
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
