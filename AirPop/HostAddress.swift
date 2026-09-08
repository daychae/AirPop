import Foundation

/// Local IPv4 addresses, shown on the Mac so the address can be typed into the
/// phone when Bonjour discovery fails on a venue network.
enum HostAddress {
  struct Entry: Identifiable, Equatable {
    var id: String { "\(interface)-\(address)" }
    let interface: String
    let address: String
  }

  static func activeIPv4() -> [Entry] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    var entries: [Entry] = []
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(pointer.pointee.ifa_flags)
      guard
        flags & IFF_UP == IFF_UP,
        flags & IFF_LOOPBACK == 0,
        let addressPointer = pointer.pointee.ifa_addr,
        addressPointer.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        addressPointer,
        socklen_t(addressPointer.pointee.sa_len),
        &buffer,
        socklen_t(buffer.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard result == 0 else { continue }

      let address = String(cString: buffer)
      // Link-local still works for Bonjour and TCP, which is exactly the case
      // for a USB connection without DHCP, so it is deliberately kept.
      guard !address.hasPrefix("127.") else { continue }

      entries.append(
        Entry(
          interface: String(cString: pointer.pointee.ifa_name),
          address: address
        ))
    }
    return entries
  }

  /// The address most likely to be reachable from the phone.
  static func preferred() -> Entry? {
    let entries = activeIPv4()
    // en0 is Wi-Fi on Apple silicon Macs; a tethered iPhone shows up on a
    // higher-numbered interface, which is why routable addresses win over
    // link-local ones rather than sorting purely by name.
    return entries.first { !$0.address.hasPrefix("169.254.") } ?? entries.first
  }
}
