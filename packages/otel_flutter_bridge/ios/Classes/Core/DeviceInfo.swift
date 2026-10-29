import Foundation

/// Resource attributes that describe the device and its OS, from the
/// OpenTelemetry semantic conventions. Never personal: the model
/// identifier (`iPhone15,2`) and the OS version are the same for millions of
/// devices. Read once, from Foundation only, so it works on any thread.
public enum DeviceInfo {
  public static let resourceAttributes: [String: String] = {
    var out = [
      "device.manufacturer": "Apple",
      "os.type": "darwin",
      "os.version": osVersion(ProcessInfo.processInfo.operatingSystemVersion),
    ]
    #if os(iOS)
    out["os.name"] = "iOS"
    #elseif os(macOS)
    out["os.name"] = "macOS"
    #endif
    if let model = modelIdentifier() { out["device.model.identifier"] = model }
    return out
  }()

  /// `17.5` or `17.5.1`, as `UIDevice.systemVersion` writes it.
  static func osVersion(_ v: OperatingSystemVersion) -> String {
    v.patchVersion == 0
      ? "\(v.majorVersion).\(v.minorVersion)"
      : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }

  /// `iPhone15,2`. On the simulator, the model it simulates.
  static func modelIdentifier() -> String? {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
       !simulated.isEmpty {
      return simulated
    }
    var info = utsname()
    guard uname(&info) == 0 else { return nil }
    let machine = withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return machine.isEmpty ? nil : machine
  }
}
