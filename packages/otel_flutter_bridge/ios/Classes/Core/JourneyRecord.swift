import Foundation

/// Journey keys and event names shared with Dart (`lib/src/semantics.dart`).
/// See `docs/specs/journey.md`.
public enum JourneyKeys {
  public static let eventName = "event.name"
  public static let uid = "log.record.uid"
  public static let source = "otel_flutter_bridge.source"
  public static let previousSession = "session.previous_id"
  public static let screenLabel = "journey.screen.label"
  public static let flowLabel = "journey.flow.label"
  public static let flowParent = "journey.flow.parent_instance_id"
  public static let action = "journey.action.name"
  public static let actionLabel = "journey.action.label"
  public static let actionId = "journey.action.instance_id"
  public static let outcome = "journey.outcome"
  public static let reason = "journey.outcome_reason"
  public static let durationMs = "journey.duration_ms"
  public static let errorType = "error.type"

  public static let sessionStart = "session.start"
  public static let screenView = "journey.screen.view"
  public static let actionEvent = "journey.action"
  public static let flowStart = "journey.flow.start"
  public static let flowEnd = "journey.flow.end"

  /// `device.app.lifecycle` (OpenTelemetry event conventions) and its
  /// `ios.app.state`.
  public static let appLifecycle = "device.app.lifecycle"
  public static let iosAppState = "ios.app.state"
}

/// Random ids: 128 bits as 32 lowercase hex characters, like Dart's.
public enum JourneyIds {
  public static func new() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<16).map { _ in
      String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
    }.joined()
  }
}

/// A journey event recorded in native code, in the bridge format version 1.
/// Dart turns it into an OTLP log record. See `docs/specs/native-bridge.md`.
public struct BridgeLogRecord: Equatable {
  public var name: String
  public var timeUnixNano: Int
  public var observedTimeUnixNano: Int
  public var attributes: [String: BridgeAttributeValue]
  public var traceId: String?
  public var spanId: String?
  public var flags: Int

  public init(name: String, timeUnixNano: Int, observedTimeUnixNano: Int? = nil,
              attributes: [String: BridgeAttributeValue] = [:], traceId: String? = nil,
              spanId: String? = nil, flags: Int = 1) {
    self.name = name
    self.timeUnixNano = timeUnixNano
    self.observedTimeUnixNano = observedTimeUnixNano ?? timeUnixNano
    self.attributes = attributes
    self.traceId = traceId
    self.spanId = spanId
    self.flags = flags
  }

  /// The event as a StandardMessageCodec-friendly dictionary.
  public var wireValue: [String: Any] {
    var out: [String: Any] = [
      "name": name,
      "timeUnixNano": timeUnixNano,
      "observedTimeUnixNano": observedTimeUnixNano,
      "attributes": attributes.mapValues(\.wireValue),
    ]
    if let traceId, let spanId {
      out["traceId"] = traceId
      out["spanId"] = spanId
      out["flags"] = flags
    }
    return out
  }

  /// Builds an event with the context it happened in: session (when the
  /// host owns it; otherwise Dart stamps it), user, screen, flow and flow
  /// run. `attributes` win over the context, as in Dart.
  public static func journey(_ name: String, attributes: [String: BridgeAttributeValue],
                             context: JourneyContext, timeUnixNano: Int,
                             observedTimeUnixNano: Int? = nil, traceId: String? = nil,
                             spanId: String? = nil, sampled: Bool = true) -> BridgeLogRecord {
    var attrs: [String: BridgeAttributeValue] = [
      JourneyKeys.eventName: .string(name),
      JourneyKeys.uid: .string(JourneyIds.new()),
      JourneyKeys.source: .string("native"),
    ]
    attrs.put(AppContextKeys.session, context.sessionId)
    attrs.put(AppContextKeys.user, context.userId)
    attrs.put(AppContextKeys.screen, context.values.screen)
    attrs.put(AppContextKeys.flow, context.values.flow)
    attrs.put(AppContextKeys.flowId, context.values.flowId)
    attributes.forEach { attrs[$0.key] = $0.value }
    let linked = traceId != nil && spanId != nil
    return BridgeLogRecord(name: name, timeUnixNano: timeUnixNano,
                           observedTimeUnixNano: observedTimeUnixNano,
                           attributes: attrs, traceId: linked ? traceId : nil,
                           spanId: linked ? spanId : nil, flags: sampled ? 1 : 0)
  }
}

public extension Dictionary where Key == String, Value == BridgeAttributeValue {
  /// Sets `key` to the string `value`, or leaves it out when nil.
  mutating func put(_ key: String, _ value: String?) {
    if let value { self[key] = .string(value) }
  }
}

/// Builds the event batches sent to Dart (`exportEvents`).
public enum BridgeLogBatchEncoder {
  /// Splits `records` into batches of at most `maxBatchSize` events.
  public static func encode(_ records: [BridgeLogRecord], maxBatchSize: Int) -> [[String: Any]] {
    let size = max(1, maxBatchSize)
    return stride(from: 0, to: records.count, by: size).map { start in
      let chunk = records[start..<min(start + size, records.count)]
      return ["v": BridgeBatchEncoder.formatVersion, "events": chunk.map(\.wireValue)]
    }
  }
}

/// The journey state both sides share (current screen, open flow runs,
/// user, and the host's session), and the changes that keep it the same:
/// each side applies a change locally and sends it to the other, which
/// applies it without sending it back. See `docs/specs/native-bridge.md`.
public enum JourneySync {
  public static func screen(_ code: String?) -> [String: Any] {
    var op: [String: Any] = ["op": "screen"]
    if let code { op["code"] = code }
    return op
  }

  public static func user(_ id: String?) -> [String: Any] {
    var op: [String: Any] = ["op": "user"]
    if let id { op["id"] = id }
    return op
  }

  public static func flowStart(_ run: JourneyFlowState) -> [String: Any] {
    ["op": "flowStart", "run": run.wireValue]
  }

  public static func flowEnd(_ instanceId: String) -> [String: Any] {
    ["op": "flowEnd", "instanceId": instanceId]
  }

  public static func session(_ id: String) -> [String: Any] {
    ["op": "session", "id": id]
  }

  /// Applies a change sent by Dart. Unknown or malformed changes are
  /// ignored.
  public static func apply(_ op: Any?, to store: AppContextStore) {
    guard let m = op as? [String: Any] else { return }
    switch m["op"] as? String {
    case "screen":
      store.screen = m["code"] as? String
    case "user":
      let id = m["id"] as? String
      store.userId = (id?.isEmpty ?? true) ? nil : id
    case "flowStart":
      if let run = JourneyFlowState(wire: m["run"]) { store.pushFlow(run) }
    case "flowEnd":
      if let id = m["instanceId"] as? String { store.removeFlow(instanceId: id) }
    default:
      break
    }
  }

  /// The state as sent to Dart in the reply to `ready`.
  public static func state(of store: AppContextStore) -> [String: Any] {
    let ctx = store.snapshot
    var out: [String: Any] = ["flows": store.openFlows.map(\.wireValue)]
    if let screen = ctx.values.screen { out["screen"] = screen }
    if let user = ctx.userId { out["userId"] = user }
    if let session = ctx.sessionId { out["sessionId"] = session }
    return out
  }

  /// Merges the state Dart sent in `ready`: what native code already knows
  /// wins, Dart fills the gaps, and runs open on either side stay open.
  /// Dart then adopts the merged state (`state(of:)`).
  public static func merge(_ dartState: Any?, into store: AppContextStore) {
    guard let m = dartState as? [String: Any] else { return }
    if store.screen == nil, let screen = m["screen"] as? String { store.screen = screen }
    if store.userId == nil, let user = m["userId"] as? String, !user.isEmpty { store.userId = user }
    let known = Set(store.openFlows.map(\.instanceId))
    for wire in m["flows"] as? [Any] ?? [] {
      if let run = JourneyFlowState(wire: wire), !known.contains(run.instanceId) {
        store.pushFlow(run)
      }
    }
  }
}
