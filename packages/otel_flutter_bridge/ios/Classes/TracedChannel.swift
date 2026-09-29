import Flutter
import Foundation
import OpenTelemetryApi

public extension OtelFlutterBridge {
  /// Wraps a method channel handler so every call is a span that continues
  /// the Dart trace (`invokeTraced` in Dart), named `channel/method` like the
  /// Dart client span.
  ///
  /// - The span is current while `handler` runs, so requests through
  ///   `HTTPClientSpan` / `TracedURLSession`, `bind`, `task` and
  ///   `invokeTraced` inside it become its children.
  /// - It ends when `result` is called, so its duration includes async work
  ///   and waits (a request, a callback queued in a manager).
  /// - `FlutterError` sets `error.type` to its code;
  ///   `FlutterMethodNotImplemented` to `not_implemented`.
  ///
  /// ```swift
  /// channel.setMethodCallHandler(OtelFlutterBridge.shared.traced(channel: "app/native") { call, result in
  ///   ...
  /// })
  /// ```
  ///
  /// `channel` must be the same name used in Dart. A handler that never
  /// calls `result` leaves its span open, as it leaves the Dart call waiting.
  func traced(channel: String,
              _ handler: @escaping FlutterMethodCallHandler) -> FlutterMethodCallHandler {
    return { call, result in
      let span = self.startSpan("\(channel)/\(call.method)", arguments: call.arguments, kind: .server,
                                attributes: [
                                  "rpc.system": .string("flutter_platform_channel"),
                                  "rpc.service": .string(channel),
                                  "rpc.method": .string(call.method),
                                ])
      let ended = OnceFlag()
      let tracedResult: FlutterResult = { value in
        if ended.claim() {
          if let error = value as? FlutterError {
            span.setAttribute(key: "error.type", value: error.code)
            span.status = .error(description: error.code)
          } else if let object = value as? NSObject, object === FlutterMethodNotImplemented {
            span.setAttribute(key: "error.type", value: "not_implemented")
            span.status = .error(description: "not_implemented")
          }
          span.end()
        }
        result(value)
      }
      TraceContext.with(span) { handler(call, tracedResult) }
    }
  }
}

public extension FlutterMethodChannel {
  /// `invokeMethod` carrying the current span, its screen and flow, so the
  /// Dart handler (`setTracedMethodCallHandler`) continues the trace.
  func invokeTraced(_ method: String, arguments: [String: Any]? = nil,
                    result: FlutterResult? = nil) {
    invokeMethod(method, arguments: OtelFlutterBridge.shared.withTraceContext(arguments),
                 result: result)
  }
}
