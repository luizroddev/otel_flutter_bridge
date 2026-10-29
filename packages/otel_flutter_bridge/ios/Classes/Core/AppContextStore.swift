import Foundation

/// Attribute keys shared with Dart (`lib/src/semantics.dart`).
public enum AppContextKeys {
  public static let screen = "app.screen.name"
  public static let flow = "journey.flow.name"
  public static let flowId = "journey.flow.instance_id"
  public static let user = "user.id"
  public static let session = "session.id"
}

/// The screen, flow and flow run a span was started in.
public struct AppContextValues: Equatable {
  public var screen: String?
  public var flow: String?
  public var flowId: String?

  public init(screen: String? = nil, flow: String? = nil, flowId: String? = nil) {
    self.screen = screen
    self.flow = flow
    self.flowId = flowId
  }
}

/// One open run of a flow, started on either side (`Journey.startFlow` in
/// Swift or Dart).
public struct JourneyFlowState: Equatable {
  public let code: String
  public let label: String?
  public let instanceId: String
  public let parentInstanceId: String?
  public let startUnixNano: Int

  public init(code: String, label: String?, instanceId: String, parentInstanceId: String?,
              startUnixNano: Int) {
    self.code = code
    self.label = label
    self.instanceId = instanceId
    self.parentInstanceId = parentInstanceId
    self.startUnixNano = startUnixNano
  }

  /// The run as sent through the channel.
  public var wireValue: [String: Any] {
    var out: [String: Any] = ["code": code, "instanceId": instanceId, "startUnixNano": startUnixNano]
    if let label { out["label"] = label }
    if let parentInstanceId { out["parentInstanceId"] = parentInstanceId }
    return out
  }

  /// Reads a run sent through the channel; nil when malformed.
  public init?(wire: Any?) {
    guard let m = wire as? [String: Any],
          let code = m["code"] as? String,
          let id = m["instanceId"] as? String, !id.isEmpty,
          let start = (m["startUnixNano"] as? NSNumber)?.intValue
    else { return nil }
    self.init(code: code, label: m["label"] as? String, instanceId: id,
              parentInstanceId: m["parentInstanceId"] as? String, startUnixNano: start)
  }
}

/// What a journey event or a span is stamped with at one moment.
public struct JourneyContext: Equatable {
  public var values: AppContextValues
  public var userId: String?
  public var sessionId: String?

  public init(values: AppContextValues = AppContextValues(), userId: String? = nil,
              sessionId: String? = nil) {
    self.values = values
    self.userId = userId
    self.sessionId = sessionId
  }
}

/// Where the user is in the host app (screen, open flow runs, user), and
/// what each recent span was stamped with, so its children copy it and one
/// trace never mixes screens. Thread-safe and bounded: the oldest span
/// entries are dropped after `capacity`, and a child whose parent was
/// dropped takes the current values.
///
/// The Swift and Dart `Journey` keep it the same on both sides through the
/// bridge (`JourneySync`).
///
/// Values must be fixed names such as `Orders.list`, never text with ids.
public final class AppContextStore: @unchecked Sendable {
  private let lock = NSLock()
  private var current = AppContextValues()
  private var bySpan: [String: AppContextValues] = [:]
  private var order: [String] = []
  private var flows: [JourneyFlowState] = []
  private var user: String?
  private var session: String?

  public let capacity: Int

  public init(capacity: Int = 1024) {
    self.capacity = max(1, capacity)
  }

  /// The current screen. Set it when a native screen appears, or use
  /// `Journey.screen`, which also records the view and tells Dart.
  public var screen: String? {
    get { lock.locked { current.screen } }
    set { lock.locked { current.screen = newValue } }
  }

  /// The current flow (a journey across screens). `Journey.startFlow` sets
  /// it; set it by hand only when you do not use `Journey`.
  public var flow: String? {
    get { lock.locked { current.flow } }
    set { lock.locked { current.flow = newValue } }
  }

  /// The current run of `flow`, or nil.
  public var flowId: String? {
    get { lock.locked { current.flowId } }
    set { lock.locked { current.flowId = newValue } }
  }

  /// The current user id (`user.id`), or nil. Set with `Journey.setUser`.
  public var userId: String? {
    get { lock.locked { user } }
    set { lock.locked { user = newValue } }
  }

  /// The host app's session id, when it owns the session
  /// (`OtelFlutterBridge.setSession`); otherwise nil and Dart stamps it.
  public var sessionId: String? {
    lock.locked { session }
  }

  /// Sets the host's session. Returns false when it is already the current
  /// one.
  @discardableResult
  public func setSession(_ id: String) -> Bool {
    lock.locked {
      guard session != id else { return false }
      session = id
      return true
    }
  }

  /// Open flow runs, oldest first. The last one is the current flow.
  public var openFlows: [JourneyFlowState] {
    lock.locked { flows }
  }

  /// The open run of the flow `code` started last, or nil.
  public func openFlow(code: String) -> JourneyFlowState? {
    lock.locked { flows.last { $0.code == code } }
  }

  /// Adds an open run and makes it the current flow. A run already known
  /// is ignored.
  public func pushFlow(_ run: JourneyFlowState) {
    lock.locked {
      guard !flows.contains(where: { $0.instanceId == run.instanceId }) else { return }
      flows.append(run)
      current.flow = run.code
      current.flowId = run.instanceId
    }
  }

  /// Removes an open run. When it was the current flow, the run it was
  /// nested in (if any) becomes current again. Returns the run, or nil when
  /// it was not open (already ended, here or in Dart).
  @discardableResult
  public func removeFlow(instanceId: String) -> JourneyFlowState? {
    lock.locked {
      guard let index = flows.firstIndex(where: { $0.instanceId == instanceId }) else { return nil }
      let run = flows.remove(at: index)
      // Only when the context still points at this run: a value set by
      // hand is left alone.
      if current.flowId == instanceId {
        current.flow = flows.last?.code
        current.flowId = flows.last?.instanceId
      }
      return run
    }
  }

  /// The context of a journey event or span that happens now.
  public var snapshot: JourneyContext {
    lock.locked { JourneyContext(values: current, userId: user, sessionId: session) }
  }

  public func clear() {
    lock.locked {
      current = AppContextValues()
      bySpan.removeAll()
      order.removeAll()
      flows.removeAll()
      user = nil
      session = nil
    }
  }

  /// What the span with `spanId` was stamped with, if still known.
  public func values(forSpanId spanId: String) -> AppContextValues? {
    lock.locked { bySpan[spanId] }
  }

  /// Values for a new span: its local parent's, or the current ones.
  public func valuesForNewSpan(parentSpanId: String?) -> AppContextValues {
    lock.locked {
      if let parentSpanId, let parent = bySpan[parentSpanId] { return parent }
      return current
    }
  }

  /// Remembers what the span with `spanId` was stamped with.
  public func register(_ values: AppContextValues, forSpanId spanId: String) {
    lock.locked {
      if bySpan.updateValue(values, forKey: spanId) == nil { order.append(spanId) }
      while order.count > capacity {
        bySpan.removeValue(forKey: order.removeFirst())
      }
    }
  }
}

private extension NSLock {
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
