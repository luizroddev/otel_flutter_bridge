import Foundation

/// Parses and formats the W3C `traceparent` header without depending on the
/// OpenTelemetry SDK. https://www.w3.org/TR/trace-context/#traceparent-header
public enum TraceparentCodec {
  public static let header = "traceparent"
  /// Key under which Dart puts the trace context in channel arguments.
  public static let channelContextKey = "_otel"

  public struct Value: Equatable {
    public let traceId: String
    public let spanId: String
    public let flags: UInt8
    public var sampled: Bool { flags & 1 == 1 }
  }

  public static func parse(_ raw: String?) -> Value? {
    guard let raw else { return nil }
    let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 4,
          isHex(parts[0], length: 2), parts[0] != "ff",
          isHex(parts[1], length: 32), parts[1] != Substring(String(repeating: "0", count: 32)),
          isHex(parts[2], length: 16), parts[2] != Substring(String(repeating: "0", count: 16)),
          isHex(parts[3], length: 2), let flags = UInt8(parts[3], radix: 16)
    else { return nil }
    return Value(traceId: String(parts[1]), spanId: String(parts[2]), flags: flags)
  }

  public static func format(traceId: String, spanId: String, sampled: Bool) -> String {
    "00-\(traceId)-\(spanId)-\(sampled ? "01" : "00")"
  }

  /// Reads the `traceparent` Dart put in platform channel arguments.
  public static func fromChannelArguments(_ arguments: Any?) -> Value? {
    guard let args = arguments as? [String: Any],
          let ctx = args[channelContextKey] as? [String: Any]
    else { return nil }
    return parse(ctx[header] as? String)
  }

  /// Reads the `app.screen` / `app.flow` Dart put next to the
  /// `traceparent` in channel arguments. Nil when there is no trace context.
  public static func appContext(fromChannelArguments arguments: Any?) -> AppContextValues? {
    guard let args = arguments as? [String: Any],
          let ctx = args[channelContextKey] as? [String: Any],
          parse(ctx[header] as? String) != nil
    else { return nil }
    return AppContextValues(screen: ctx[AppContextKeys.screen] as? String,
                            flow: ctx[AppContextKeys.flow] as? String)
  }

  /// The value to put under `channelContextKey` in the arguments of a call
  /// from native code to Dart, read by `runWithTraceContext` in Dart.
  public static func channelContext(traceparent: String, app: AppContextValues?) -> [String: Any] {
    var ctx: [String: Any] = [header: traceparent]
    if let screen = app?.screen { ctx[AppContextKeys.screen] = screen }
    if let flow = app?.flow { ctx[AppContextKeys.flow] = flow }
    return ctx
  }

  private static func isHex(_ s: Substring, length: Int) -> Bool {
    s.count == length && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }
}
