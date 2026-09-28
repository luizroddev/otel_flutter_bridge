import Flutter
import UIKit

/// Flutter plugin: the native end of the bridge channel.
public class OtelFlutterBridgePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "otel_flutter_bridge", binaryMessenger: registrar.messenger())
    let instance = OtelFlutterBridgePlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    OtelFlutterBridge.shared.queue.setSink { [weak channel] batch in
      let send: () -> Void = { channel?.invokeMethod("exportSpans", arguments: batch) }
      if Thread.isMainThread {
        send()
      } else {
        DispatchQueue.main.async(execute: send)
      }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ready":
      guard args["v"] as? Int == BridgeBatchEncoder.formatVersion else {
        result(FlutterError(code: "unsupported_version", message: "Bridge format version mismatch", details: nil))
        return
      }
      OtelFlutterBridge.shared.queue.markReady(
        enabled: args["enabled"] as? Bool ?? true,
        maxBatchSize: args["maxBatchSize"] as? Int ?? 64)
      result(nil)
    case "setEnabled":
      OtelFlutterBridge.shared.queue.setEnabled(args["enabled"] as? Bool ?? true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
