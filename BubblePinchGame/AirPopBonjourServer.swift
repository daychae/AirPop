import Foundation
import Network

@MainActor
final class AirPopBonjourServer: ObservableObject {
  enum ListenerState: Equatable {
    case stopped
    case starting
    case advertising
    case waiting(String)
    case failed(String)
  }

  @Published private(set) var state: ListenerState = .stopped
  @Published private(set) var connectedDeviceCount = 0
  @Published private(set) var receivedBlowCount = 0
  @Published private(set) var lastStrength = 0.0

  private let serviceType = "_airpop._tcp"
  private let queue = DispatchQueue(label: "AirPop.BonjourServer")
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var connectedIDs: Set<UUID> = []
  private var receiveBuffers: [UUID: Data] = [:]
  private var onBlow: ((Double) -> Void)?

  var isAdvertising: Bool {
    if case .advertising = state {
      return true
    }
    return false
  }

  func start(onBlow: @escaping (Double) -> Void) {
    self.onBlow = onBlow
    guard listener == nil else { return }

    do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .wifi

      let listener = try NWListener(using: parameters)
      let hostName = Host.current().localizedName ?? "Mac"
      listener.service = NWListener.Service(
        name: "AirPop on \(hostName)",
        type: serviceType
      )
      listener.stateUpdateHandler = { [weak self] newState in
        Task { @MainActor [weak self] in
          self?.handleListenerState(newState)
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor [weak self] in
          self?.accept(connection)
        }
      }

      self.listener = listener
      state = .starting
      listener.start(queue: queue)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil

    for connection in connections.values {
      connection.cancel()
    }
    connections.removeAll()
    connectedIDs.removeAll()
    receiveBuffers.removeAll()
    connectedDeviceCount = 0
    state = .stopped
  }

  private func handleListenerState(_ newState: NWListener.State) {
    switch newState {
    case .setup:
      state = .starting
    case .waiting(let error):
      state = .waiting(error.localizedDescription)
    case .ready:
      state = .advertising
    case .failed(let error):
      state = .failed(error.localizedDescription)
      listener?.cancel()
      listener = nil
    case .cancelled:
      if listener != nil {
        state = .stopped
        listener = nil
      }
    @unknown default:
      state = .waiting("알 수 없는 네트워크 상태")
    }
  }

  private func accept(_ connection: NWConnection) {
    let id = UUID()
    connections[id] = connection
    receiveBuffers[id] = Data()

    connection.stateUpdateHandler = { [weak self] newState in
      Task { @MainActor [weak self] in
        self?.handleConnectionState(newState, id: id)
      }
    }
    connection.start(queue: queue)
    receiveNextMessage(from: connection, id: id)
  }

  private func handleConnectionState(_ newState: NWConnection.State, id: UUID) {
    switch newState {
    case .ready:
      connectedIDs.insert(id)
      connectedDeviceCount = connectedIDs.count
    case .failed, .cancelled:
      removeConnection(id: id)
    default:
      break
    }
  }

  private func receiveNextMessage(from connection: NWConnection, id: UUID) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 16_384
    ) { [weak self] data, _, isComplete, error in
      Task { @MainActor [weak self] in
        guard let self else { return }

        if let data, !data.isEmpty {
          self.consume(data, from: id)
        }

        if isComplete || error != nil {
          connection.cancel()
          self.removeConnection(id: id)
        } else if self.connections[id] != nil {
          self.receiveNextMessage(from: connection, id: id)
        }
      }
    }
  }

  private func consume(_ data: Data, from id: UUID) {
    var buffer = receiveBuffers[id, default: Data()]
    buffer.append(data)

    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      let line = Data(buffer[..<newlineIndex])
      buffer.removeSubrange(...newlineIndex)

      guard
        !line.isEmpty,
        let message = try? JSONDecoder().decode(BlowMessage.self, from: line),
        message.type == "blow"
      else {
        continue
      }

      let strength = min(max(message.strength, 0), 1)
      lastStrength = strength
      receivedBlowCount += 1
      onBlow?(strength)
    }

    if buffer.count > 65_536 {
      buffer.removeAll(keepingCapacity: true)
    }
    receiveBuffers[id] = buffer
  }

  private func removeConnection(id: UUID) {
    connections.removeValue(forKey: id)
    connectedIDs.remove(id)
    receiveBuffers.removeValue(forKey: id)
    connectedDeviceCount = connectedIDs.count
  }
}

private struct BlowMessage: Decodable {
  let type: String
  let strength: Double
  let timestamp: TimeInterval
}
