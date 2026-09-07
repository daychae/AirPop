import Foundation
import Network
import UIKit

/// Sends blow strength to the Mac game and keeps a measurable link to it.
///
/// State lives on `queue`, not the main actor. Send timestamps are taken at the
/// moment the bytes are handed to the transport rather than when a caller asks
/// for a send, so a busy UI thread cannot inflate the measured latency.
final class AirPopConnection: ObservableObject {

  enum ConnectionState: Equatable {
    case stopped
    case searching
    case connecting(String)
    case connected(String)
    /// Connected at the TCP level, but the Mac app has stopped answering.
    case unresponsive(String)
    case failed(String)
  }

  // MARK: - Published state (main thread only)

  @Published private(set) var state: ConnectionState = .stopped
  @Published private(set) var sentCount = 0
  @Published private(set) var ackCount = 0
  @Published private(set) var droppedCount = 0
  @Published private(set) var rtt = AirPopSampleStats.empty
  @Published private(set) var isStreaming = false
  @Published private(set) var sessionShortID: String?
  @Published private(set) var manualTarget: String?

  /// Kept for source compatibility with the existing blow UI.
  @Published private(set) var sentBlowCount = 0

  var isConnected: Bool {
    if case .connected = state { return true }
    return false
  }

  var isLinkUsable: Bool {
    switch state {
    case .connected, .unresponsive: return true
    default: return false
    }
  }

  var statusTitle: String {
    switch state {
    case .stopped: "연결 정지됨"
    case .searching: "Mac의 AirPop 검색 중"
    case .connecting: "AirPop에 연결 중"
    case .connected: "Mac과 연결됨"
    case .unresponsive: "Mac이 응답하지 않음"
    case .failed: "연결을 확인해 주세요"
    }
  }

  var statusDetail: String {
    switch state {
    case .stopped:
      "검색을 시작하면 같은 네트워크의 게임을 찾습니다."
    case .searching:
      manualTarget.map { "\($0)에 연결을 시도합니다." }
        ?? "Mac에서 AirPop 게임을 먼저 실행해 주세요."
    case .connecting(let name):
      "\(name)에 연결하고 있습니다."
    case .connected(let name):
      "\(name) · 전송 \(sentCount)회"
    case .unresponsive(let name):
      "\(name)에 연결은 되어 있으나 응답이 없습니다. Mac 앱을 확인해 주세요."
    case .failed(let message):
      message
    }
  }

  // MARK: - Network queue state

  private let queue = DispatchQueue(label: "AirPop.BonjourClient")
  private var browser: NWBrowser?
  private var connection: NWConnection?
  private var connectionEndpoint: NWEndpoint?
  private var manualEndpoint: NWEndpoint?
  private var isRunning = false

  private var sessionID = ""
  private var sequence = 0
  private var receiveBuffer = Data()

  private struct Draft {
    let type: AirPopMessageType
    let strength: Double?
    let forceAck: Bool
  }

  private var pendingDraft: Draft?
  private var isSending = false
  private var localDroppedCount = 0
  private var pendingAcks: [Int: Double] = [:]
  private var lastAckRequestAtMillis: Double?
  private var lastAckReceivedAtMillis: Double?
  private var latestRTT: Double?
  private var rttTracker = AirPopSampleTracker()

  private var streamTimer: DispatchSourceTimer?
  private var watchdogTimer: DispatchSourceTimer?
  private var reconnectTimer: DispatchSourceTimer?
  private var diagnosticsMode = false

  /// A requested ack that never arrives within this window means the peer app
  /// is no longer reading, even though TCP still reports a healthy connection.
  private let unresponsiveThresholdMillis: Double = 2_500

  // MARK: - Lifecycle

  func start() {
    queue.async { [weak self] in
      guard let self, !self.isRunning else { return }
      self.isRunning = true
      self.startWatchdog()

      if let manualEndpoint = self.manualEndpoint {
        self.publish { $0.state = .searching }
        self.connect(to: manualEndpoint)
      } else {
        self.startBrowser()
      }
    }
  }

  func restart() {
    stop()
    start()
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.isRunning = false
      self.teardownTimers()
      self.connection?.cancel()
      self.connection = nil
      self.connectionEndpoint = nil
      self.browser?.cancel()
      self.browser = nil
      self.resetSendState()
      self.publish {
        $0.state = .stopped
        $0.isStreaming = false
        $0.sessionShortID = nil
      }
    }
  }

  /// Connect to a typed-in address instead of relying on discovery. Bonjour and
  /// mDNS are the first thing a managed venue network blocks, and this is the
  /// only recovery that does not need the network to cooperate.
  func connectManually(host: String, port: UInt16) {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let port = NWEndpoint.Port(rawValue: port) else { return }

    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmed), port: port)
    queue.async { [weak self] in
      guard let self else { return }
      self.manualEndpoint = endpoint
      self.browser?.cancel()
      self.browser = nil
      self.connection?.cancel()
      self.connection = nil
      self.isRunning = true
      self.startWatchdog()
      self.publish { $0.manualTarget = "\(trimmed):\(port.rawValue)" }
      self.connect(to: endpoint)
    }
  }

  func clearManualTarget() {
    queue.async { [weak self] in
      guard let self else { return }
      self.manualEndpoint = nil
      self.publish { $0.manualTarget = nil }
      self.connection?.cancel()
      self.connection = nil
      if self.isRunning { self.startBrowser() }
    }
  }

  // MARK: - Sending

  /// A completed blow. Kept on the existing call site until phase 2 replaces it
  /// with live start/update/end events.
  func sendBlow(strength: Double) {
    enqueue(
      Draft(
        type: .blow,
        strength: min(max(strength, 0), 1),
        forceAck: false
      ))
  }

  /// One diagnostic message that does not involve the microphone.
  func sendPing() {
    enqueue(Draft(type: .ping, strength: nil, forceAck: true))
  }

  /// Drives the same send path the phase 2 blow stream will use, at the same
  /// rate, without touching the microphone.
  func startTestStream() {
    queue.async { [weak self] in
      guard let self, self.streamTimer == nil else { return }
      self.diagnosticsMode = true

      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(
        deadline: .now(),
        repeating: AirPopLink.targetSendInterval,
        leeway: .milliseconds(5)
      )
      timer.setEventHandler { [weak self] in
        self?.enqueue(Draft(type: .ping, strength: nil, forceAck: false))
      }
      self.streamTimer = timer
      timer.resume()
      self.publish { $0.isStreaming = true }
    }
  }

  func stopTestStream() {
    queue.async { [weak self] in
      guard let self else { return }
      self.streamTimer?.cancel()
      self.streamTimer = nil
      self.diagnosticsMode = false
      self.publish { $0.isStreaming = false }
    }
  }

  func resetCounters() {
    queue.async { [weak self] in
      guard let self else { return }
      self.localDroppedCount = 0
      self.rttTracker.reset()
      self.publish {
        $0.sentCount = 0
        $0.ackCount = 0
        $0.droppedCount = 0
        $0.sentBlowCount = 0
        $0.rtt = .empty
      }
    }
  }

  /// Replaces any unsent value rather than queueing behind it. Under a stalled
  /// link this keeps at most one message waiting, so recovery does not deliver
  /// a burst of readings the player made seconds ago.
  private func enqueue(_ draft: Draft) {
    queue.async { [weak self] in
      guard let self, self.connection != nil else { return }

      guard !self.isSending else {
        if self.pendingDraft != nil {
          self.localDroppedCount += 1
          let dropped = self.localDroppedCount
          self.publish { $0.droppedCount = dropped }
        }
        self.pendingDraft = draft
        return
      }
      self.flush(draft)
    }
  }

  private func flush(_ draft: Draft) {
    guard let connection, isLinkReady else { return }

    sequence += 1
    let wantsAck = draft.forceAck || shouldRequestAck()
    // Taken here, immediately before handing the bytes over, so queueing on the
    // caller's side never shows up as network latency.
    let sentAtMillis = AirPopClock.millis

    let message = AirPopMessage(
      type: draft.type,
      sessionID: sessionID,
      sequence: sequence,
      sentAtMillis: sentAtMillis,
      wantsAck: wantsAck,
      strength: draft.strength,
      lastRTTMillis: latestRTT,
      droppedCount: localDroppedCount
    )

    guard let data = try? AirPopWire.encode(message) else { return }

    if wantsAck {
      pendingAcks[sequence] = sentAtMillis
      lastAckRequestAtMillis = sentAtMillis
      prunePendingAcks(now: sentAtMillis)
    }

    isSending = true
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] error in
        // Delivered on `queue`, the connection's own queue.
        guard let self else { return }
        self.isSending = false

        if let error {
          self.publish { $0.state = .failed(error.localizedDescription) }
        } else {
          let isBlow = draft.type == .blow
          self.publish {
            $0.sentCount += 1
            if isBlow { $0.sentBlowCount += 1 }
          }
        }

        if let next = self.pendingDraft {
          self.pendingDraft = nil
          self.flush(next)
        }
      })
  }

  private var isLinkReady: Bool {
    connection?.state == .ready
  }

  private func shouldRequestAck() -> Bool {
    if diagnosticsMode { return true }
    guard let last = lastAckRequestAtMillis else { return true }
    return AirPopClock.elapsed(since: last)
      >= AirPopLink.ackHeartbeatInterval * 1000
  }

  private func prunePendingAcks(now: Double) {
    guard pendingAcks.count > 64 else { return }
    pendingAcks = pendingAcks.filter { now - $0.value < 5_000 }
  }

  // MARK: - Discovery

  private func startBrowser() {
    browser?.cancel()
    publish { $0.state = .searching }

    let browser = NWBrowser(
      for: .bonjour(type: AirPopLink.serviceType, domain: nil),
      using: AirPopLink.makeParameters()
    )
    browser.stateUpdateHandler = { [weak self] state in
      self?.handleBrowserState(state)
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      self?.handle(results: results)
    }

    self.browser = browser
    browser.start(queue: queue)
  }

  private func handleBrowserState(_ state: NWBrowser.State) {
    switch state {
    case .setup:
      publish { $0.state = .searching }
    case .ready:
      if connection == nil {
        publish { $0.state = .searching }
      }
    case .waiting(let error):
      publish { $0.state = .failed(error.localizedDescription) }
    case .failed(let error):
      publish { $0.state = .failed(error.localizedDescription) }
      browser?.cancel()
      browser = nil
      scheduleReconnect { [weak self] in self?.startBrowser() }
    case .cancelled:
      break
    @unknown default:
      publish { $0.state = .failed("알 수 없는 네트워크 상태") }
    }
  }

  private func handle(results: Set<NWBrowser.Result>) {
    guard
      isRunning,
      manualEndpoint == nil,
      connection == nil,
      let result = results.sorted(by: {
        $0.endpoint.debugDescription < $1.endpoint.debugDescription
      }).first
    else {
      return
    }
    connect(to: result.endpoint)
  }

  // MARK: - Connection

  private func connect(to endpoint: NWEndpoint) {
    reconnectTimer?.cancel()
    reconnectTimer = nil
    connectionEndpoint = endpoint

    let connection = NWConnection(to: endpoint, using: AirPopLink.makeParameters())
    let name = Self.displayName(for: endpoint)
    publish { $0.state = .connecting(name) }

    connection.stateUpdateHandler = { [weak self] state in
      self?.handleConnectionState(state, name: name)
    }
    self.connection = connection
    connection.start(queue: queue)
  }

  private func handleConnectionState(_ state: NWConnection.State, name: String) {
    switch state {
    case .ready:
      beginSession(name: name)
      receiveNext()

    case .waiting(let error):
      publish { $0.state = .failed(error.localizedDescription) }

    case .failed(let error):
      publish { $0.state = .failed(error.localizedDescription) }
      connection?.cancel()
      connection = nil
      resetSendState()
      scheduleReconnect { [weak self] in
        guard let self, let endpoint = self.connectionEndpoint else { return }
        self.connect(to: endpoint)
      }

    case .cancelled:
      if isRunning, connection != nil {
        connection = nil
        resetSendState()
        publish { $0.state = .searching }
      }

    default:
      break
    }
  }

  /// A fresh session on every connection, with the sequence rewound. The Mac
  /// discards anything carrying an older session, which is what stops a
  /// reconnect from replaying input the player produced before the drop.
  private func beginSession(name: String) {
    sessionID = UUID().uuidString
    sequence = 0
    receiveBuffer.removeAll(keepingCapacity: true)
    resetSendState()
    lastAckReceivedAtMillis = AirPopClock.millis

    let shortID = String(sessionID.prefix(6)).uppercased()
    publish {
      $0.state = .connected(name)
      $0.sessionShortID = shortID
    }

    enqueue(Draft(type: .hello, strength: nil, forceAck: true))
  }

  private func resetSendState() {
    pendingDraft = nil
    isSending = false
    pendingAcks.removeAll()
    lastAckRequestAtMillis = nil
    latestRTT = nil
  }

  private func receiveNext() {
    guard let connection else { return }
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 16_384
    ) { [weak self] data, _, isComplete, error in
      let receivedAtMillis = AirPopClock.millis
      guard let self else { return }

      if let data, !data.isEmpty {
        self.receiveBuffer.append(data)
        for message in AirPopWire.drain(&self.receiveBuffer) {
          self.handle(message, at: receivedAtMillis)
        }
      }

      if isComplete || error != nil {
        connection.cancel()
      } else if self.connection === connection {
        self.receiveNext()
      }
    }
  }

  private func handle(_ message: AirPopMessage, at receivedAtMillis: Double) {
    guard message.sessionID == sessionID else { return }

    switch message.type {
    case .ack, .helloAck:
      guard let sentAt = pendingAcks.removeValue(forKey: message.sequence) else {
        return
      }
      let roundTrip = max(0, receivedAtMillis - sentAt)
      rttTracker.record(roundTrip)
      latestRTT = roundTrip
      lastAckReceivedAtMillis = receivedAtMillis

      let stats = rttTracker.snapshot()
      publish {
        $0.ackCount += 1
        $0.rtt = stats
        if case .unresponsive(let name) = $0.state {
          $0.state = .connected(name)
        }
      }

    default:
      break
    }
  }

  // MARK: - Liveness watchdog

  private func startWatchdog() {
    guard watchdogTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.checkResponsiveness()
    }
    watchdogTimer = timer
    timer.resume()
  }

  /// TCP reports `.ready` and keeps accepting sends long after the peer app has
  /// stopped reading, so a missing ack is the only fast signal that the Mac
  /// side is no longer consuming input.
  private func checkResponsiveness() {
    guard
      let lastRequest = lastAckRequestAtMillis,
      let lastReceived = lastAckReceivedAtMillis,
      lastRequest > lastReceived
    else {
      return
    }

    guard
      AirPopClock.elapsed(since: lastReceived) > unresponsiveThresholdMillis
    else {
      return
    }

    publish {
      if case .connected(let name) = $0.state {
        $0.state = .unresponsive(name)
      }
    }
  }

  private func scheduleReconnect(_ work: @escaping () -> Void) {
    guard isRunning else { return }
    reconnectTimer?.cancel()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1.0)
    timer.setEventHandler { [weak self] in
      self?.reconnectTimer = nil
      guard self?.isRunning == true else { return }
      work()
    }
    reconnectTimer = timer
    timer.resume()
  }

  private func teardownTimers() {
    streamTimer?.cancel()
    streamTimer = nil
    watchdogTimer?.cancel()
    watchdogTimer = nil
    reconnectTimer?.cancel()
    reconnectTimer = nil
    diagnosticsMode = false
  }

  private static func displayName(for endpoint: NWEndpoint) -> String {
    switch endpoint {
    case .service(let name, _, _, _): return name
    case .hostPort(let host, let port): return "\(host):\(port.rawValue)"
    default: return "AirPop"
    }
  }

  private func publish(_ mutate: @escaping (AirPopConnection) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      mutate(self)
    }
  }
}
