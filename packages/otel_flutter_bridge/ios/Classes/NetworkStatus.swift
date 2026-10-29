import Foundation
import Network

/// The device's connection type, kept up to date by `NWPathMonitor` and
/// recorded on native HTTP spans as `network.connection.type`
/// (OpenTelemetry network conventions): `wifi`, `cell`, `wired`,
/// `unavailable` or `unknown`. Started by `OtelFlutterBridge.start`.
final class NetworkStatus: @unchecked Sendable {
  static let shared = NetworkStatus()

  private let lock = NSLock()
  private var monitor: NWPathMonitor?
  private var current: String?

  /// The connection type, or nil before the first update.
  var connectionType: String? {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      self?.update(NetworkStatus.connectionType(of: path))
    }
    monitor.start(queue: DispatchQueue(label: "otel_flutter_bridge.network", qos: .utility))
    self.monitor = monitor
  }

  private func update(_ value: String) {
    lock.lock()
    current = value
    lock.unlock()
  }

  static func connectionType(of path: NWPath) -> String {
    guard path.status == .satisfied else { return "unavailable" }
    if path.usesInterfaceType(.wifi) { return "wifi" }
    if path.usesInterfaceType(.cellular) { return "cell" }
    if path.usesInterfaceType(.wiredEthernet) { return "wired" }
    return "unknown"
  }
}
