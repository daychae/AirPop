import Foundation
import Network

@MainActor
final class AirPopConnection: ObservableObject {
  enum ConnectionState: Equatable {
    case stopped
    case searching
    case connecting(String)
    case connected(String)
    case failed(String)
  }

  @Published private(set) var state: ConnectionState = .stopped
  @Published private(set) var sentBlowCount = 0

  private let serviceType = "_airpop._tcp"
  private let queue = DispatchQueue(label: "AirPop.BonjourClient")
  private var browser: NWBrowser?
  private var connection: NWConnection?
  private var connectionEndpoint: NWEndpoint?
  private var reconnectTask: Task<Void, Never>?
  private var isRunning = false

  var isConnected: Bool {
    if case .connected = state {
      return true
    }
    return false
  }

  var statusTitle: String {
    switch state {
    case .stopped:
      "연결 정지됨"
    case .searching:
      "Mac의 AirPop 검색 중"
    case .connecting:
      "AirPop에 연결 중"
    case .connected:
      "Mac과 연결됨"
    case .failed:
      "연결을 확인해 주세요"
    }
  }

  var statusDetail: String {
    switch state {
    case .stopped:
      "검색을 시작하면 같은 Wi‑Fi의 게임을 찾습니다."
    case .searching:
      "Mac에서 AirPop 게임을 먼저 실행해 주세요."
    case .connecting(let name):
      "\(name)에 연결하고 있습니다."
    case .connected(let name):
      "\(name) · 불기 신호 \(sentBlowCount)회 전송"
    case .failed(let message):
      message
    }
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    state = .searching

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.requiredInterfaceType = .wifi

    let browser = NWBrowser(
      for: .bonjour(type: serviceType, domain: nil),
      using: parameters
    )
    browser.stateUpdateHandler = { [weak self] newState in
      Task { @MainActor [weak self] in
        self?.handleBrowserState(newState)
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor [weak self] in
        self?.handle(results: results)
      }
    }

    self.browser = browser
    browser.start(queue: queue)
  }

  func restart() {
    stop()
    start()
  }

  func stop() {
    isRunning = false
    reconnectTask?.cancel()
    reconnectTask = nil
    connection?.cancel()
    connection = nil
    connectionEndpoint = nil
    browser?.cancel()
    browser = nil
    state = .stopped
  }

  func sendBlow(strength: Double) {
    guard isConnected, let connection else { return }

    let message = BlowMessage(
      type: "blow",
      strength: min(max(strength, 0), 1),
      timestamp: Date().timeIntervalSince1970
    )

    do {
      var data = try JSONEncoder().encode(message)
      data.append(0x0A)
      connection.send(
        content: data,
        completion: .contentProcessed { [weak self] error in
          Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
              self.state = .failed(error.localizedDescription)
            } else {
              self.sentBlowCount += 1
            }
          }
        })
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  private func handleBrowserState(_ newState: NWBrowser.State) {
    switch newState {
    case .setup:
      state = .searching
    case .ready:
      if connection == nil {
        state = .searching
      }
    case .waiting(let error):
      state = .failed(error.localizedDescription)
    case .failed(let error):
      state = .failed(error.localizedDescription)
      browser?.cancel()
      browser = nil
      scheduleBrowserRestart()
    case .cancelled:
      break
    @unknown default:
      state = .failed("알 수 없는 네트워크 상태")
    }
  }

  private func handle(results: Set<NWBrowser.Result>) {
    guard
      isRunning,
      connection == nil,
      let result = results.sorted(by: {
        $0.endpoint.debugDescription < $1.endpoint.debugDescription
      }).first
    else {
      return
    }
    connect(to: result.endpoint)
  }

  private func connect(to endpoint: NWEndpoint) {
    reconnectTask?.cancel()
    connectionEndpoint = endpoint

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.requiredInterfaceType = .wifi
    let connection = NWConnection(to: endpoint, using: parameters)
    let name = serviceName(from: endpoint)
    state = .connecting(name)

    connection.stateUpdateHandler = { [weak self] newState in
      Task { @MainActor [weak self] in
        self?.handleConnectionState(newState, name: name)
      }
    }
    self.connection = connection
    connection.start(queue: queue)
  }

  private func handleConnectionState(_ newState: NWConnection.State, name: String) {
    switch newState {
    case .ready:
      state = .connected(name)
    case .waiting(let error):
      state = .failed(error.localizedDescription)
    case .failed(let error):
      state = .failed(error.localizedDescription)
      connection?.cancel()
      connection = nil
      scheduleConnectionRetry()
    case .cancelled:
      if isRunning, connection != nil {
        connection = nil
        state = .searching
      }
    default:
      break
    }
  }

  private func scheduleConnectionRetry() {
    guard let endpoint = connectionEndpoint, isRunning else { return }
    reconnectTask?.cancel()
    reconnectTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled, self.isRunning, self.connection == nil else {
        return
      }
      self.connect(to: endpoint)
    }
  }

  private func scheduleBrowserRestart() {
    guard isRunning else { return }
    reconnectTask?.cancel()
    reconnectTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled, self.isRunning else { return }
      self.isRunning = false
      self.start()
    }
  }

  private func serviceName(from endpoint: NWEndpoint) -> String {
    if case .service(let name, _, _, _) = endpoint {
      return name
    }
    return "AirPop"
  }
}

private struct BlowMessage: Encodable {
  let type: String
  let strength: Double
  let timestamp: TimeInterval
}
