import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// OpenTelemetry Swift exporter that sends finished native spans to Dart,
/// where they go through the same redaction and destination as Dart spans.
public final class FlutterChannelSpanExporter: SpanExporter, @unchecked Sendable {
  private let queue: PendingSpanQueue

  public init(queue: PendingSpanQueue) {
    self.queue = queue
  }

  @discardableResult
  public func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    exportNow(spans)
  }

  public func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    flushNow()
  }

  public func shutdown(explicitTimeout: TimeInterval?) {
    _ = flushNow()
  }

  @discardableResult
  public func export(spans: [SpanData], explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
    exportNow(spans)
  }

  public func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
    flushNow()
  }

  public func shutdown(explicitTimeout: TimeInterval?) async {
    _ = flushNow()
  }

  private func exportNow(_ spans: [SpanData]) -> SpanExporterResultCode {
    queue.enqueue(spans.map(Self.convert))
    return .success
  }

  private func flushNow() -> SpanExporterResultCode {
    queue.flush()
    return .success
  }

  static func convert(_ span: SpanData) -> BridgeSpan {
    let (code, message): (BridgeSpan.StatusCode, String?) = {
      switch span.status {
      case .ok: return (.ok, nil)
      case .unset: return (.unset, nil)
      case let .error(description): return (.error, description)
      }
    }()
    return BridgeSpan(
      traceId: span.traceId.hexString,
      spanId: span.spanId.hexString,
      parentSpanId: span.parentSpanId.map(\.hexString),
      name: span.name,
      kind: kind(span.kind),
      startTimeUnixNano: nanos(span.startTime),
      endTimeUnixNano: nanos(span.endTime),
      statusCode: code,
      statusMessage: message,
      attributes: attributes(span.attributes),
      events: span.events.map {
        .init(name: $0.name, timeUnixNano: nanos($0.timestamp), attributes: attributes($0.attributes))
      },
      links: span.links.map {
        .init(traceId: $0.context.traceId.hexString, spanId: $0.context.spanId.hexString,
              attributes: attributes($0.attributes))
      },
      scopeName: span.instrumentationScope.name,
      scopeVersion: span.instrumentationScope.version,
      flags: span.traceFlags.sampled ? 1 : 0
    )
  }

  static func nanos(_ date: Date) -> Int {
    Int((date.timeIntervalSince1970 * 1_000_000_000).rounded())
  }

  static func kind(_ kind: SpanKind) -> BridgeSpan.Kind {
    switch kind {
    case .internal: return .internal
    case .server: return .server
    case .client: return .client
    case .producer: return .producer
    case .consumer: return .consumer
    }
  }

  static func attributes(_ attrs: [String: AttributeValue]) -> [String: BridgeAttributeValue] {
    attrs.compactMapValues(value)
  }

  static func value(_ v: AttributeValue) -> BridgeAttributeValue? {
    switch v {
    case let .string(s): return .string(s)
    case let .bool(b): return .bool(b)
    case let .int(i): return .int(i)
    case let .double(d): return .double(d)
    case let .array(a): return .array(a.values.compactMap(value))
    case let .stringArray(a): return .array(a.map { .string($0) })
    case let .boolArray(a): return .array(a.map { .bool($0) })
    case let .intArray(a): return .array(a.map { .int($0) })
    case let .doubleArray(a): return .array(a.map { .double($0) })
    case .set: return nil // Nested maps are dropped, as on the Dart side.
    }
  }
}
