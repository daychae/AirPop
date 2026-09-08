import Foundation
import Network

// MARK: - Message types

enum AirPopMessageType: String, Codable {
  /// iPhone → Mac. First message on every connection. Claims a session.
  case hello
  /// Mac → iPhone. Confirms the session and reports the Mac's protocol version.
  case helloAck
  /// iPhone → Mac. Diagnostic signal that does not involve the microphone.
  case ping
  /// Mac → iPhone. Echo used for round-trip timing and liveness.
  case ack
  /// iPhone → Mac. A completed blow event. Superseded by the live events
  /// below; kept so an older build fails visibly rather than silently.
  case blow

  /// iPhone → Mac. Blowing began.
  case blowStart
  /// iPhone → Mac. Latest strength while blowing, roughly every 50ms.
  case blowUpdate
  /// iPhone → Mac. Blowing stopped.
  case blowEnd

  /// iPhone → Mac. Readiness that is not part of the blow stream.
  case status
  /// Mac → iPhone. The Mac owns round state; the phone mirrors it.
  case gameState

  /// State transitions carry meaning in their order and must never be dropped
  /// to make room for a newer message. Only a strength reading is disposable:
  /// the next one supersedes it 50ms later.
  var isCritical: Bool {
    switch self {
    case .hello, .blowStart, .blowEnd, .blow, .status: return true
    case .ping, .blowUpdate, .ack, .helloAck, .gameState: return false
    }
  }

  var carriesStrength: Bool {
    switch self {
    case .blow, .blowStart, .blowUpdate: return true
    default: return false
    }
  }
}

/// Round state as it travels between the two apps.
///
/// Deliberately separate from the Mac's own `GamePhase`: the phone shows a
/// different screen for each of these and has no use for the scene-level
/// details, and a wire format that changes whenever the game's internal
/// enumeration changes would break the pairing at the worst moment.
enum AirPopGamePhase: String, Codable {
  case ready
  case countdown
  case playing
  case pausedHandsLost
  case pausedPeerLost
  case result
}

// MARK: - Envelope

/// One newline-delimited JSON message.
///
/// The envelope is deliberately flat rather than an enum with associated
/// values: the wire format stays readable in logs and `nc` output, and adding
/// a case in phase 2 (`blowStart` / `blowUpdate` / `blowEnd`) costs one enum
/// case instead of a new payload type.
struct AirPopMessage: Codable, Equatable {
  var v: Int
  var type: AirPopMessageType
  var sessionID: String
  var sequence: Int

  /// Sender's monotonic clock reading. Only ever compared against the *same*
  /// device's clock, so the two devices need no synchronization.
  var sentAtMillis: Double

  /// The Mac replies only when this is set. See `AirPopLink.ackHeartbeatInterval`.
  var wantsAck: Bool

  /// Normalized blow strength, 0...1. Present on `blow`.
  var strength: Double?

  /// Round trip the phone measured for a previous message. Carried upstream so
  /// the Mac diagnostics panel can show it without reading the phone's screen.
  var lastRTTMillis: Double?

  /// How many intermediate values the phone replaced while a send was in
  /// flight. The Mac uses this to tell expected sequence gaps from real bugs.
  var droppedCount: Int?

  /// Device name, on `hello` / `helloAck`.
  var peerName: String?

  /// `sentAtMillis` copied back verbatim, on `ack`.
  var echoSentAtMillis: Double?

  /// Whether the phone has finished calibrating its microphone, on `status`.
  var micReady: Bool?

  /// Round state, on `gameState`.
  var gamePhase: AirPopGamePhase?
  var countdownValue: Int?

  init(
    v: Int = AirPopLink.protocolVersion,
    type: AirPopMessageType,
    sessionID: String,
    sequence: Int,
    sentAtMillis: Double = AirPopClock.millis,
    wantsAck: Bool = false,
    strength: Double? = nil,
    lastRTTMillis: Double? = nil,
    droppedCount: Int? = nil,
    peerName: String? = nil,
    echoSentAtMillis: Double? = nil,
    micReady: Bool? = nil,
    gamePhase: AirPopGamePhase? = nil,
    countdownValue: Int? = nil
  ) {
    self.v = v
    self.type = type
    self.sessionID = sessionID
    self.sequence = sequence
    self.sentAtMillis = sentAtMillis
    self.wantsAck = wantsAck
    self.strength = strength
    self.lastRTTMillis = lastRTTMillis
    self.droppedCount = droppedCount
    self.peerName = peerName
    self.echoSentAtMillis = echoSentAtMillis
    self.micReady = micReady
    self.gamePhase = gamePhase
    self.countdownValue = countdownValue
  }

  // Decoding is hand written so a missing optional-with-default field (notably
  // `wantsAck`) does not fail the whole message. Encoding stays synthesized,
  // which omits nil fields.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
    type = try container.decode(AirPopMessageType.self, forKey: .type)
    sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
    sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
    sentAtMillis =
      try container.decodeIfPresent(Double.self, forKey: .sentAtMillis) ?? 0
    wantsAck = try container.decodeIfPresent(Bool.self, forKey: .wantsAck) ?? false
    strength = try container.decodeIfPresent(Double.self, forKey: .strength)
    lastRTTMillis = try container.decodeIfPresent(Double.self, forKey: .lastRTTMillis)
    droppedCount = try container.decodeIfPresent(Int.self, forKey: .droppedCount)
    peerName = try container.decodeIfPresent(String.self, forKey: .peerName)
    echoSentAtMillis =
      try container.decodeIfPresent(Double.self, forKey: .echoSentAtMillis)
    micReady = try container.decodeIfPresent(Bool.self, forKey: .micReady)
    gamePhase = try container.decodeIfPresent(
      AirPopGamePhase.self, forKey: .gamePhase)
    countdownValue = try container.decodeIfPresent(
      Int.self, forKey: .countdownValue)
  }

  /// Strength clamped to the range the game expects.
  var normalizedStrength: Double {
    min(max(strength ?? 0, 0), 1)
  }
}

// MARK: - Shared constants and transport configuration

enum AirPopLink {
  static let serviceType = "_airpop._tcp"
  static let protocolVersion = 2

  /// Fixed so the phone can fall back to a typed-in address when discovery
  /// fails. The Mac falls back to an automatic port if this one is taken and
  /// shows whichever port it actually got.
  static let preferredPort: NWEndpoint.Port = 51888

  /// The Mac treats strength as 0 when nothing has arrived for this long.
  static let staleTimeout: TimeInterval = 0.25

  /// Target interval for the phase 2 blow stream, and for the phase 1 test
  /// stream that stands in for it.
  static let targetSendInterval: TimeInterval = 0.05

  /// During normal play the phone asks for an ack this often. That is the only
  /// thing proving the Mac app is still consuming messages: a TCP connection
  /// stays `.ready` and keeps accepting sends long after the peer app has
  /// stopped reading.
  static let ackHeartbeatInterval: TimeInterval = 1.0

  /// Discard a receive buffer that grows past this without a newline.
  static let maximumBufferBytes = 64 * 1024

  /// TCP options and parameters used by *both* apps.
  ///
  /// - `noDelay` disables Nagle. Without it, 50ms of small packets collide with
  ///   delayed ACK and add up to 40ms for no reason.
  /// - Keepalive makes a dead peer visible in a few seconds instead of minutes.
  /// - `includePeerToPeer` keeps the AWDL path available when the venue network
  ///   blocks device-to-device traffic.
  /// - No `requiredInterfaceType`: pinning to Wi-Fi excludes both peer-to-peer
  ///   and the USB interface, which are the two fallbacks that matter on site.
  static func makeParameters() -> NWParameters {
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    tcpOptions.enableKeepalive = true
    tcpOptions.keepaliveIdle = 2
    tcpOptions.keepaliveCount = 2
    tcpOptions.keepaliveInterval = 1
    tcpOptions.connectionTimeout = 5

    let parameters = NWParameters(tls: nil, tcp: tcpOptions)
    parameters.includePeerToPeer = true
    parameters.allowLocalEndpointReuse = true
    parameters.serviceClass = .responsiveData
    return parameters
  }
}

// MARK: - Newline framing

enum AirPopWire {
  static let delimiter: UInt8 = 0x0A

  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  static func encode(_ message: AirPopMessage) throws -> Data {
    var data = try encoder.encode(message)
    data.append(delimiter)
    return data
  }

  /// Pulls every complete line out of `buffer`, leaving any partial tail behind.
  ///
  /// Undecodable lines are skipped rather than failing the batch, so one bad
  /// message cannot stall the stream.
  static func drain(_ buffer: inout Data) -> [AirPopMessage] {
    var messages: [AirPopMessage] = []

    while let newlineIndex = buffer.firstIndex(of: delimiter) {
      let line = Data(buffer[..<newlineIndex])
      buffer.removeSubrange(...newlineIndex)

      guard !line.isEmpty else { continue }
      if let message = try? decoder.decode(AirPopMessage.self, from: line) {
        messages.append(message)
      }
    }

    if buffer.count > AirPopLink.maximumBufferBytes {
      buffer.removeAll(keepingCapacity: true)
    }
    return messages
  }
}
