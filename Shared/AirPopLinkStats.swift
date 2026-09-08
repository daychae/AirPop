import Foundation

/// Percentile summary of a stream of millisecond samples.
///
/// Used for two different things: the Mac summarizes message arrival intervals,
/// the phone summarizes round trips. The math is identical, so it lives here
/// rather than being written twice.
struct AirPopSampleStats: Equatable {
  var p50: Double = 0
  var p95: Double = 0
  var maximum: Double = 0
  var latest: Double = 0
  var count: Int = 0

  static let empty = AirPopSampleStats()
}

/// Fixed-size ring buffer of samples.
///
/// A round lasts 30 seconds and the blow stream targets 20Hz, so 240 samples
/// cover roughly the last 12 seconds. That is long enough to show a stall and
/// short enough that recovery becomes visible right away.
struct AirPopSampleTracker {
  private var samples: [Double] = []
  private var writeIndex = 0
  private var latest: Double = 0
  private let capacity = 240

  mutating func record(_ millis: Double) {
    latest = millis
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
    latest = 0
  }

  func snapshot() -> AirPopSampleStats {
    guard !samples.isEmpty else { return .empty }
    let sorted = samples.sorted()

    return AirPopSampleStats(
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      maximum: sorted[sorted.count - 1],
      latest: latest,
      count: sorted.count
    )
  }

  private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let position = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[min(max(position, 0), sorted.count - 1)]
  }
}
