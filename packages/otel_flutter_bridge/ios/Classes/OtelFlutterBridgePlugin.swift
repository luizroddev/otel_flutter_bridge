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
    let send: (String, [String: Any]) -> Void = { [weak channel] method, batch in
      let call: () -> Void = { channel?.invokeMethod(method, arguments: batch) }
      if Thread.isMainThread {
        call()
      } else {
        DispatchQueue.main.async(execute: call)
      }
    }
    OtelFlutterBridge.shared.queue.setSink { send("exportSpans", $0) }
    OtelFlutterBridge.shared.events.setSink { send("exportEvents", $0) }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let bridge = OtelFlutterBridge.shared
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ready":
      guard args["v"] as? Int == BridgeBatchEncoder.formatVersion else {
        result(FlutterError(code: "unsupported_version", message: "Bridge format version mismatch", details: nil))
        return
      }
      let enabled = args["enabled"] as? Bool ?? true
      let maxBatchSize = args["maxBatchSize"] as? Int ?? 64
      // Both sides end with the same journey state: native values win,
      // Dart fills the gaps, then Dart adopts the reply.
      JourneySync.merge(args["journey"], into: bridge.appContext)
      bridge.setJourneySink { [weak channel = self.channel] op in
        channel?.invokeMethod("journey", arguments: op)
      }
      bridge.setDartFlush { [weak channel = self.channel] done in
        guard let channel else { return done() }
        channel.invokeMethod("flush", arguments: nil) { _ in done() }
      }
      var resource: [String: Any] = DeviceInfo.resourceAttributes
      bridge.queue.resource.forEach { resource[$0.key] = $0.value.wireValue }
      result(["journey": JourneySync.state(of: bridge.appContext), "resource": resource])
      bridge.queue.markReady(enabled: enabled, maxBatchSize: maxBatchSize)
      bridge.events.markReady(enabled: enabled, maxBatchSize: maxBatchSize)
    case "setEnabled":
      let enabled = args["enabled"] as? Bool ?? true
      bridge.queue.setEnabled(enabled)
      bridge.events.setEnabled(enabled)
      result(nil)
    case "journey":
      JourneySync.apply(call.arguments, to: bridge.appContext)
      result(nil)
    case "export":
      guard let handler = bridge.exportHandler,
            let signal = args["signal"] as? String,
            let body = (args["body"] as? FlutterStandardTypedData)?.data
      else {
        result(false)
        return
      }
      let export = TelemetryExport(signal: signal,
                                   url: (args["url"] as? String).flatMap { URL(string: $0) },
                                   headers: args["headers"] as? [String: String] ?? [:],
                                   body: body)
      let replied = OnceFlag()
      handler(export) { ok in
        guard replied.claim() else { return }
        DispatchQueue.main.async { result(ok) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
