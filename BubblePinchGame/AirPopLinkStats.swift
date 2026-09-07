import Foundation

/// Percentile summary of message arrival intervals, in milliseconds.
struct AirPopIntervalStats: Equatable {
  var p50: Double = 0
  var p95: Double = 0
  var maximum: Double = 0
  var count: Int = 0

  static let empty = AirPopIntervalStats()
}

/// Fixed-size ring buffer of interval samples.
///
/// A round lasts 30 seconds and the blow stream targets 20Hz, so 240 samples
/// cover roughly the last 12 seconds of input. That is long enough to show a
/// stall and short enough that recovery is visible right away.
struct AirPopIntervalTracker {
  private var samples: [Double] = []
  private var writeIndex = 0
  private let capacity = 240

  mutating func record(_ millis: Double) {
    if samples.count < capacity {
      samples.append(millis)
    } else {
      samples[writeIndex] = millis
      writeIndex = (writeIndex + 1) % capacity
    }
  }

  mutating func reset() {
    samples.removeAll(keepingCapacity: true)
    writeIndex = 0
  }

  func snapshot() -> AirPopIntervalStats {
    guard !samples.isEmpty else { return .empty }
    let sorted = samples.sorted()

    return AirPopIntervalStats(
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      maximum: sorted[sorted.count - 1],
      count: sorted.count
    )
  }

  private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let position = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[min(max(position, 0), sorted.count - 1)]
  }
}
