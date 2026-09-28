import Foundation

/// A value that can cross the platform channel as a span attribute.
public enum BridgeAttributeValue: Equatable {
  case string(String)
  case bool(Bool)
  case int(Int)
  case double(Double)
  case array([BridgeAttributeValue])

  var wireValue: Any {
    switch self {
    case let .string(v): return v
    case let .bool(v): return v
    case let .int(v): return v
    case let .double(v): return v
    case let .array(v): return v.map(\.wireValue)
    }
  }
}

/// A finished native span in the bridge format, version 1.
/// See `docs/specs/native-bridge.md`. Foundation only, so it is testable
/// without Flutter or the OpenTelemetry SDK.
public struct BridgeSpan: Equatable {
  public enum Kind: String { case `internal`, server, client, producer, consumer }
  public enum StatusCode: String { case unset, ok, error }

  public struct Event: Equatable {
    public var name: String
    public var timeUnixNano: Int
    public var attributes: [String: BridgeAttributeValue]
    public init(name: String, timeUnixNano: Int, attributes: [String: BridgeAttributeValue] = [:]) {
      self.name = name
      self.timeUnixNano = timeUnixNano
      self.attributes = attributes
    }
  }

  public struct Link: Equatable {
    public var traceId: String
    public var spanId: String
    public var attributes: [String: BridgeAttributeValue]
    public init(traceId: String, spanId: String, attributes: [String: BridgeAttributeValue] = [:]) {
      self.traceId = traceId
      self.spanId = spanId
      self.attributes = attributes
    }
  }

  public var traceId: String
  public var spanId: String
  public var parentSpanId: String?
  public var name: String
  public var kind: Kind
  public var startTimeUnixNano: Int
  public var endTimeUnixNano: Int
  public var statusCode: StatusCode
  public var statusMessage: String?
  public var attributes: [String: BridgeAttributeValue]
  public var events: [Event]
  public var links: [Link]
  public var scopeName: String
  public var scopeVersion: String?
  public var flags: Int

  public init(traceId: String, spanId: String, parentSpanId: String? = nil, name: String,
              kind: Kind = .internal, startTimeUnixNano: Int, endTimeUnixNano: Int,
              statusCode: StatusCode = .unset, statusMessage: String? = nil,
              attributes: [String: BridgeAttributeValue] = [:], events: [Event] = [],
              links: [Link] = [], scopeName: String = "native", scopeVersion: String? = nil,
              flags: Int = 1) {
    self.traceId = traceId
    self.spanId = spanId
    self.parentSpanId = parentSpanId
    self.name = name
    self.kind = kind
    self.startTimeUnixNano = startTimeUnixNano
    self.endTimeUnixNano = endTimeUnixNano
    self.statusCode = statusCode
    self.statusMessage = statusMessage
    self.attributes = attributes
    self.events = events
    self.links = links
    self.scopeName = scopeName
    self.scopeVersion = scopeVersion
    self.flags = flags
  }

  /// The span as a StandardMessageCodec-friendly dictionary.
  public var wireValue: [String: Any] {
    var out: [String: Any] = [
      "traceId": traceId,
      "spanId": spanId,
      "name": name,
      "kind": kind.rawValue,
      "startTimeUnixNano": startTimeUnixNano,
      "endTimeUnixNano": endTimeUnixNano,
      "status": ["code": statusCode.rawValue, "message": statusMessage ?? ""],
      "attributes": attributes.mapValues(\.wireValue),
      "flags": flags,
      "scope": ["name": scopeName, "version": scopeVersion ?? ""],
    ]
    if let parentSpanId { out["parentSpanId"] = parentSpanId }
    if !events.isEmpty {
      out["events"] = events.map {
        ["name": $0.name, "timeUnixNano": $0.timeUnixNano,
         "attributes": $0.attributes.mapValues(\.wireValue)] as [String: Any]
      }
    }
    if !links.isEmpty {
      out["links"] = links.map {
        ["traceId": $0.traceId, "spanId": $0.spanId,
         "attributes": $0.attributes.mapValues(\.wireValue)] as [String: Any]
      }
    }
    return out
  }
}

/// Builds the batches sent to Dart.
public enum BridgeBatchEncoder {
  public static let formatVersion = 1

  /// Splits [spans] into batches of at most [maxBatchSize] spans.
  public static func encode(_ spans: [BridgeSpan], resource: [String: BridgeAttributeValue],
                            maxBatchSize: Int) -> [[String: Any]] {
    let size = max(1, maxBatchSize)
    return stride(from: 0, to: spans.count, by: size).map { start in
      let chunk = spans[start..<min(start + size, spans.count)]
      return [
        "v": formatVersion,
        "resource": resource.mapValues(\.wireValue),
        "spans": chunk.map(\.wireValue),
      ]
    }
  }
}
