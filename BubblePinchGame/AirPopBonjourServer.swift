import Foundation
import Network

/// Receives blow input from the AirPuff iPhone app.
///
/// Timing note: every measurement in this class is taken on `queue`, the
/// network queue, before anything hops to the main actor. The Mac runs
/// SpriteKit, Vision hand tracking and SwiftUI on the main thread, so a
/// timestamp taken after a main-thread hop would fold frame scheduling into
/// what looks like network latency. Parsing happens here too; only finished
/// values cross over to the published properties.
final class AirPopBonjourServer: ObservableObject {

  enum LinkState: Equatable {
    case stopped
    case starting
    case advertising
    case connected
    case protocolMismatch(peerVersion: Int)
    case failed(String)
  }

  // MARK: - Published state (main thread only)

  @Published private(set) var linkState: LinkState = .stopped
  @Published private(set) var listenerPort: UInt16 = 0
  @Published private(set) var peerName: String?
  @Published private(set) var sessionShortID: String?
  @Published private(set) var pathDescription: String?

  @Published private(set) var receivedCount = 0
  @Published private(set) var sequenceGapCount = 0
  @Published private(set) var peerDroppedCount = 0
  @Published private(set) var peerReportedRTT: Double?
  @Published private(set) var intervalStats = AirPopIntervalStats.empty

  /// Monotonic reading of the most recent accepted message. Published only when
  /// a message arrives, so the diagnostics view can animate elapsed time with a
  /// `TimelineView` instead of forcing a re-render on a timer.
  @Published private(set) var lastMessageAtMillis: Double?

  /// False once `AirPopLink.staleTimeout` passes with no input.
  @Published private(set) var isLive = false
  @Published private(set) var latestStrength = 0.0

  var isAdvertising: Bool {
    switch linkState {
    case .advertising, .connected: return true
    default: return false
    }
  }

  var isPeerConnected: Bool { linkState == .connected }

  // MARK: - Network queue state

  private let queue = DispatchQueue(label: "AirPop.BonjourServer")
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var buffers: [ObjectIdentifier: Data] = [:]
  private var activeConnection: NWConnection?
  private var activeSessionID: String?
  private var lastSequence = -1
  private var lastReceivedAtMillis: Double?
  private var intervals = AirPopIntervalTracker()
  private var staleTimer: DispatchSourceTimer?
  private var didFallBackToAutomaticPort = false
  private var onBlow: ((Double) -> Void)?

  // MARK: - Lifecycle

  func start(onBlow: @escaping (Double) -> Void) {
    queue.async { [weak self] in
      guard let self, self.listener == nil else { return }
      self.onBlow = onBlow
      self.didFallBackToAutomaticPort = false
      self.startListener(onPreferredPort: true)
      self.startStaleTimer()
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.staleTimer?.cancel()
      self.staleTimer = nil
      self.listener?.cancel()
      self.listener = nil

      for connection in self.connections.values {
        connection.cancel()
      }
      self.connections.removeAll()
      self.buffers.removeAll()
      self.activeConnection = nil
      self.activeSessionID = nil
      self.lastSequence = -1
      self.lastReceivedAtMillis = nil
      self.intervals.reset()

      self.publish {
        $0.linkState = .stopped
        $0.listenerPort = 0
        $0.peerName = nil
        $0.sessionShortID = nil
        $0.pathDescription = nil
        $0.isLive = false
        $0.latestStrength = 0
        $0.lastMessageAtMillis = nil
        $0.intervalStats = .empty
      }
    }
  }

  // MARK: - Listener

  private func startListener(onPreferredPort: Bool) {
    let parameters = AirPopLink.makeParameters()

    do {
      let listener =
        onPreferredPort
        ? try NWListener(using: parameters, on: AirPopLink.preferredPort)
        : try NWListener(using: parameters)

      let hostName = Host.current().localizedName ?? "Mac"
      listener.service = NWListener.Service(
        name: "AirPop on \(hostName)",
        type: AirPopLink.serviceType
      )
      listener.stateUpdateHandler = { [weak self] state in
        self?.handleListenerState(state)
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }

      self.listener = listener
      publish { $0.linkState = .starting }
      listener.start(queue: queue)
    } catch {
      publish { $0.linkState = .failed(error.localizedDescription) }
    }
  }

  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .setup:
      publish { $0.linkState = .starting }

    case .ready:
      let port = listener?.port?.rawValue ?? 0
      publish {
        $0.listenerPort = port
        if $0.linkState != .connected {
          $0.linkState = .advertising
        }
      }

    case .waiting(let error):
      publish { $0.linkState = .failed(error.localizedDescription) }

    case .failed(let error):
      listener?.cancel()
      listener = nil

      // The fixed port exists so the phone can be pointed at this Mac by hand.
      // If something else already holds it, an automatic port still beats not
      // running at all; the diagnostics panel shows whichever port we got.
      if !didFallBackToAutomaticPort {
        didFallBackToAutomaticPort = true
        startListener(onPreferredPort: false)
      } else {
        publish { $0.linkState = .failed(error.localizedDescription) }
      }

    case .cancelled:
      break

    @unknown default:
      publish { $0.linkState = .failed("Unknown listener state") }
    }
  }

  // MARK: - Connections

  private func accept(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    connections[key] = connection
    buffers[key] = Data()

    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.publishPath(for: connection)
      case .failed, .cancelled:
        self.remove(connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receiveNext(on: connection)
  }

  private func remove(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    connections.removeValue(forKey: key)
    buffers.removeValue(forKey: key)

    guard activeConnection === connection else { return }
    activeConnection = nil
    activeSessionID = nil
    lastSequence = -1
    lastReceivedAtMillis = nil
    intervals.reset()

    publish {
      $0.linkState = $0.linkState == .connected ? .advertising : $0.linkState
      $0.peerName = nil
      $0.sessionShortID = nil
      $0.pathDescription = nil
      $0.isLive = false
      $0.latestStrength = 0
      $0.lastMessageAtMillis = nil
      $0.intervalStats = .empty
    }
  }

  private func receiveNext(on connection: NWConnection) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 16_384
    ) { [weak self] data, _, isComplete, error in
      // Taken here, on the network queue, before any main-thread hop.
      let receivedAtMillis = AirPopClock.millis
      guard let self else { return }

      if let data, !data.isEmpty {
        self.consume(data, from: connection, at: receivedAtMillis)
      }

      if isComplete || error != nil {
        connection.cancel()
        self.remove(connection)
      } else if self.connections[ObjectIdentifier(connection)] != nil {
        self.receiveNext(on: connection)
      }
    }
  }

  private func consume(
    _ data: Data,
    from connection: NWConnection,
    at receivedAtMillis: Double
  ) {
    let key = ObjectIdentifier(connection)
    var buffer = buffers[key] ?? Data()
    buffer.append(data)
    let messages = AirPopWire.drain(&buffer)
    buffers[key] = buffer

    for message in messages {
      handle(message, from: connection, at: receivedAtMillis)
    }
  }

  // MARK: - Message handling

  private func handle(
    _ message: AirPopMessage,
    from connection: NWConnection,
    at receivedAtMillis: Double
  ) {
    guard message.v == AirPopLink.protocolVersion else {
      publish { $0.linkState = .protocolMismatch(peerVersion: message.v) }
      connection.cancel()
      return
    }

    if message.type == .hello {
      promote(connection, with: message)
      return
    }

    // Anything arriving outside the current session is left over from a
    // connection that has already been replaced. Dropping it is what keeps a
    // reconnect from replaying stale input into the game.
    guard
      connection === activeConnection,
      let activeSessionID,
      message.sessionID == activeSessionID
    else {
      return
    }

    guard message.sequence > lastSequence else { return }
    let gap = message.sequence - lastSequence - 1
    lastSequence = message.sequence

    let interval = lastReceivedAtMillis.map { receivedAtMillis - $0 }
    if let interval {
      intervals.record(interval)
    }
    lastReceivedAtMillis = receivedAtMillis

    let stats = intervals.snapshot()
    let strength = message.type == .blow ? message.normalizedStrength : nil
    let reportedRTT = message.lastRTTMillis
    let dropped = message.droppedCount

    publish {
      $0.receivedCount += 1
      $0.sequenceGapCount += max(0, gap)
      $0.intervalStats = stats
      $0.lastMessageAtMillis = receivedAtMillis
      $0.isLive = true
      if let reportedRTT { $0.peerReportedRTT = reportedRTT }
      if let dropped { $0.peerDroppedCount = dropped }
      if let strength { $0.latestStrength = strength }
    }

    if let strength {
      DispatchQueue.main.async { [weak self] in
        self?.onBlow?(strength)
      }
    }

    if message.wantsAck {
      send(
        AirPopMessage(
          type: .ack,
          sessionID: message.sessionID,
          sequence: message.sequence,
          echoSentAtMillis: message.sentAtMillis
        ),
        on: connection
      )
    }
  }

  private func promote(_ connection: NWConnection, with message: AirPopMessage) {
    if let previous = activeConnection, previous !== connection {
      previous.cancel()
    }

    activeConnection = connection
    activeSessionID = message.sessionID
    lastSequence = message.sequence
    lastReceivedAtMillis = AirPopClock.millis
    intervals.reset()

    let name = message.peerName ?? "iPhone"
    let shortID = String(message.sessionID.prefix(6)).uppercased()
    let now = lastReceivedAtMillis

    publish {
      $0.linkState = .connected
      $0.peerName = name
      $0.sessionShortID = shortID
      $0.receivedCount = 0
      $0.sequenceGapCount = 0
      $0.peerDroppedCount = 0
      $0.peerReportedRTT = nil
      $0.intervalStats = .empty
      $0.lastMessageAtMillis = now
      $0.isLive = true
      $0.latestStrength = 0
    }
    publishPath(for: connection)

    send(
      AirPopMessage(
        type: .helloAck,
        sessionID: message.sessionID,
        sequence: message.sequence,
        peerName: Host.current().localizedName ?? "Mac",
        echoSentAtMillis: message.sentAtMillis
      ),
      on: connection
    )
  }

  private func send(_ message: AirPopMessage, on connection: NWConnection) {
    guard let data = try? AirPopWire.encode(message) else { return }
    connection.send(content: data, completion: .idempotent)
  }

  // MARK: - Staleness

  private func startStaleTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
    timer.setEventHandler { [weak self] in
      self?.checkStaleness()
    }
    staleTimer = timer
    timer.resume()
  }

  private func checkStaleness() {
    guard let lastReceivedAtMillis else { return }
    let elapsed = AirPopClock.elapsed(since: lastReceivedAtMillis) / 1000
    guard elapsed >= AirPopLink.staleTimeout else { return }

    publish {
      guard $0.isLive else { return }
      $0.isLive = false
      $0.latestStrength = 0
    }
  }

  // MARK: - Publishing

  private func publishPath(for connection: NWConnection) {
    let label = Self.pathLabel(for: connection.currentPath)
    publish { $0.pathDescription = label }
  }

  /// Which physical path the peer actually took. With Wi-Fi, peer-to-peer and
  /// USB all possible, "connected" alone does not say which one won.
  private static func pathLabel(for path: NWPath?) -> String? {
    guard let path else { return nil }
    if path.usesInterfaceType(.wiredEthernet) { return "wired / USB" }
    if path.usesInterfaceType(.wifi) { return "wi-fi" }
    if path.usesInterfaceType(.cellular) { return "cellular" }
    if path.usesInterfaceType(.loopback) { return "loopback" }
    return "other"
  }

  private func publish(_ mutate: @escaping (AirPopBonjourServer) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      mutate(self)
    }
  }
}
