import Foundation

/// Monotonic millisecond clock shared by both apps.
///
/// `Date()` jumps when the system clock is adjusted (NTP, time zone, manual
/// change), which would corrupt every latency measurement. Every timing value
/// in AirPop is derived from this clock instead.
///
/// The origin is the first access, so values are "milliseconds since this app
/// started". Two devices never compare each other's values directly: the phone
/// measures its own round trip, and the Mac measures its own receive intervals.
/// That keeps the protocol free of any clock synchronization.
enum AirPopClock {
  private static let originNanoseconds = DispatchTime.now().uptimeNanoseconds

  /// Milliseconds elapsed since this process first touched the clock.
  static var millis: Double {
    let now = DispatchTime.now().uptimeNanoseconds
    return Double(now &- originNanoseconds) / 1_000_000
  }

  /// Milliseconds between a previously captured `millis` value and now.
  static func elapsed(since start: Double) -> Double {
    max(0, millis - start)
  }
}
