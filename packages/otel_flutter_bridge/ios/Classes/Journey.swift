import Foundation
import OpenTelemetryApi

/// A screen of the app. Conform a `String` enum; `code` is the raw value:
///
/// ```swift
/// enum AppScreen: String, JourneyScreen { case home, document }
/// ```
///
/// Implement `label` to give the dashboard a readable name.
public protocol JourneyScreen {
  var code: String { get }
  var label: String? { get }
}

/// A flow: a journey across screens, such as login or checkout. Conform a
/// `String` enum, like `JourneyScreen`.
public protocol JourneyFlow {
  var code: String { get }
  var label: String? { get }
}

/// Something the user does that matters. Conform a `String` enum, like
/// `JourneyScreen`. Its code is also the span name of `Journey.begin`.
public protocol JourneyAction {
  var code: String { get }
  var label: String? { get }
}

/// Why an action or a flow run ended the way it did, from a fixed list
/// (`invalidPassword`, `blockedAccount`). Never error text or ids.
public protocol JourneyReason {
  var code: String { get }
}

public extension JourneyScreen { var label: String? { nil } }
public extension JourneyFlow { var label: String? { nil } }
public extension JourneyAction { var label: String? { nil } }

public extension JourneyScreen where Self: RawRepresentable, Self.RawValue == String {
  var code: String { rawValue }
}

public extension JourneyFlow where Self: RawRepresentable, Self.RawValue == String {
  var code: String { rawValue }
}

public extension JourneyAction where Self: RawRepresentable, Self.RawValue == String {
  var code: String { rawValue }
}

public extension JourneyReason where Self: RawRepresentable, Self.RawValue == String {
  var code: String { rawValue }
}

/// How an action or a flow run ended. `completed` means the code finished
/// and the app did not say whether that was a success.
public enum JourneyOutcome: String {
  case success, failure, cancelled, completed
}

/// The journey API for native screens, with the same contract as Dart's
/// `Journey` (`docs/specs/journey.md`): events are recorded here, sent to
/// Dart and exported with the Dart ones.
///
/// The current screen, the open flow runs and the user are shared with
/// Dart, so a flow started on a native screen can end on a Flutter one and
/// the other way round:
///
/// ```swift
/// Journey.screen(AppScreen.document)
/// let login = Journey.startFlow(AppFlow.login)
/// Journey.event(AppAction.chooseBiometric)
/// let action = Journey.begin(AppAction.confirmLogin)
/// TraceContext.with(action.span) {
///   api.login { result in
///     action.end(result.ok ? .success : .failure, reason: result.reason)
///   }
/// }
/// // Later, on either side:
/// Journey.flowRun(AppFlow.login)?.end(.success)
/// ```
///
/// Never throws because of telemetry. Thread-safe.
public enum Journey {
  static var bridge: OtelFlutterBridge { OtelFlutterBridge.shared }
  static var store: AppContextStore { bridge.appContext }

  /// The current user id, or nil.
  public static var userId: String? { store.userId }

  /// Sets the user (`user.id`) of what happens from now on, on both sides;
  /// nil clears it (logout). Use an opaque id, never an e-mail or a
  /// document number.
  public static func setUser(_ id: String?) {
    let value = (id?.isEmpty ?? true) ? nil : id
    store.userId = value
    bridge.sendJourney(JourneySync.user(value))
  }

  /// The user entered `value`. Sets the current screen on both sides and
  /// records a `journey.screen.view` event.
  public static func screen(_ value: some JourneyScreen, attributes: [String: AttributeValue] = [:]) {
    screen(named: value.code, label: value.label, attributes: attributes)
  }

  /// Like `screen(_:)`, with a plain code.
  public static func screen(named code: String, label: String? = nil,
                            attributes: [String: AttributeValue] = [:]) {
    store.screen = code
    bridge.sendJourney(JourneySync.screen(code))
    var base: [String: BridgeAttributeValue] = [:]
    base.put(JourneyKeys.screenLabel, label)
    record(JourneyKeys.screenView, merged(base, attributes))
  }

  /// Starts a run of `flow` and makes it the current flow on both sides.
  /// Records a `journey.flow.start` event. A flow started while another is
  /// current is nested in it. End it with `JourneyFlowRun.end`, here or in
  /// Dart.
  @discardableResult
  public static func startFlow(_ flow: some JourneyFlow,
                               attributes: [String: AttributeValue] = [:]) -> JourneyFlowRun {
    let run = JourneyFlowState(code: flow.code, label: flow.label, instanceId: JourneyIds.new(),
                               parentInstanceId: store.openFlows.last?.instanceId,
                               startUnixNano: nanos(Date()))
    store.pushFlow(run)
    bridge.sendJourney(JourneySync.flowStart(run))
    var base: [String: BridgeAttributeValue] = [:]
    base.put(JourneyKeys.flowLabel, run.label)
    base.put(JourneyKeys.flowParent, run.parentInstanceId)
    record(JourneyKeys.flowStart, merged(base, attributes))
    return JourneyFlowRun(run)
  }

  /// The flow run started last and not ended, on either side, or nil.
  public static var currentFlow: JourneyFlowRun? {
    store.openFlows.last.map(JourneyFlowRun.init)
  }

  /// The open run of `flow` started last, here or in Dart, or nil.
  public static func flowRun(_ flow: some JourneyFlow) -> JourneyFlowRun? {
    store.openFlow(code: flow.code).map(JourneyFlowRun.init)
  }

  /// Records an instant `action`, such as choosing an option. No span and
  /// no duration.
  public static func event(_ action: some JourneyAction, outcome: JourneyOutcome? = nil,
                           reason: (any JourneyReason)? = nil,
                           attributes: [String: AttributeValue] = [:]) {
    var base: [String: BridgeAttributeValue] = [
      JourneyKeys.action: .string(action.code),
      JourneyKeys.actionId: .string(JourneyIds.new()),
    ]
    base.put(JourneyKeys.actionLabel, action.label)
    base.put(JourneyKeys.outcome, outcome?.rawValue)
    base.put(JourneyKeys.reason, reason?.code)
    record(JourneyKeys.actionEvent, merged(base, attributes))
  }

  /// Starts a measured `action`: a span named after its code, whose parent
  /// is the current span (`TraceContext.current`). Run the work with
  /// `TraceContext.with(run.span) { ... }` so requests inside become its
  /// children, and call `end` once when it finishes, on every path.
  public static func begin(_ action: some JourneyAction,
                           attributes: [String: AttributeValue] = [:]) -> JourneyActionRun {
    JourneyActionRun(code: action.code, label: action.label, attributes: attributes)
  }

  /// Runs `body` as `action` (see `begin`). The outcome is `outcome`
  /// applied to the result, or `completed`; when `body` throws it is
  /// `failure` with `error.type`, and the error is rethrown.
  public static func track<T>(_ action: some JourneyAction,
                              attributes: [String: AttributeValue] = [:],
                              outcome: ((T) -> JourneyOutcome)? = nil,
                              reason: ((T) -> (any JourneyReason)?)? = nil,
                              _ body: () async throws -> T) async throws -> T {
    let run = begin(action, attributes: attributes)
    do {
      let result = try await TraceContext.with(run.span) { try await body() }
      run.end(outcome?(result) ?? .completed, reason: reason?(result))
      return result
    } catch {
      run.end(.failure, errorType: HTTPSemantics.errorType(statusCode: nil, error: error))
      throw error
    }
  }

  /// Records one event with the context `context` (default: now). Events
  /// inside a span (`span`, else the current one) carry its trace.
  static func record(_ name: String, _ attributes: [String: BridgeAttributeValue],
                     span: Span? = nil, time: Date = Date(), context: JourneyContext? = nil) {
    let ctx = context ?? store.snapshot
    let sc = (span ?? TraceContext.current)?.context
    let linked = sc?.isValid == true
    let record = BridgeLogRecord.journey(
      name, attributes: attributes, context: ctx, timeUnixNano: nanos(time),
      observedTimeUnixNano: nanos(Date()),
      traceId: linked ? sc?.traceId.hexString : nil,
      spanId: linked ? sc?.spanId.hexString : nil,
      sampled: sc?.traceFlags.sampled ?? true)
    bridge.events.enqueue([record])
  }

  static func nanos(_ date: Date) -> Int { FlutterChannelSpanExporter.nanos(date) }

  /// `base` plus the app's `attributes` (which win), as bridge values.
  static func merged(_ base: [String: BridgeAttributeValue],
                     _ attributes: [String: AttributeValue]) -> [String: BridgeAttributeValue] {
    var out = base
    for (key, value) in attributes {
      if let v = FlutterChannelSpanExporter.value(value) { out[key] = v }
    }
    return out
  }
}

/// One run of a flow, started here or in Dart.
public final class JourneyFlowRun {
  public let code: String
  public let label: String?
  /// Random id of this run, sent as `journey.flow.instance_id`.
  public let instanceId: String
  /// The run that was current when this one started, or nil.
  public let parentInstanceId: String?

  init(_ state: JourneyFlowState) {
    code = state.code
    label = state.label
    instanceId = state.instanceId
    parentInstanceId = state.parentInstanceId
  }

  /// Whether the run was ended, here or in Dart.
  public var isEnded: Bool {
    !Journey.store.openFlows.contains { $0.instanceId == instanceId }
  }

  /// Ends the run with `outcome` and, optionally, the `reason`. Only the
  /// first call on either side counts. When this is the current flow, the
  /// flow it was nested in becomes current again.
  public func end(_ outcome: JourneyOutcome, reason: (any JourneyReason)? = nil,
                  attributes: [String: AttributeValue] = [:]) {
    guard let run = Journey.store.removeFlow(instanceId: instanceId) else { return }
    Journey.bridge.sendJourney(JourneySync.flowEnd(run.instanceId))
    var base: [String: BridgeAttributeValue] = [
      AppContextKeys.flow: .string(run.code),
      AppContextKeys.flowId: .string(run.instanceId),
      JourneyKeys.outcome: .string(outcome.rawValue),
      JourneyKeys.durationMs: .int(max(0, (Journey.nanos(Date()) - run.startUnixNano) / 1_000_000)),
    ]
    base.put(JourneyKeys.flowLabel, run.label)
    base.put(JourneyKeys.flowParent, run.parentInstanceId)
    base.put(JourneyKeys.reason, reason?.code)
    Journey.record(JourneyKeys.flowEnd, Journey.merged(base, attributes))
  }
}

/// A measured action in progress. See `Journey.begin`.
public final class JourneyActionRun {
  /// The action's span. Make it current while the work runs.
  public let span: Span
  /// Random id of this run, sent as `journey.action.instance_id`.
  public let instanceId: String

  private let attributes: [String: BridgeAttributeValue]
  private let context: JourneyContext
  private let start = Date()
  private let ended = OnceFlag()

  init(code: String, label: String?, attributes: [String: AttributeValue]) {
    let id = JourneyIds.new()
    var base: [String: BridgeAttributeValue] = [
      JourneyKeys.action: .string(code),
      JourneyKeys.actionId: .string(id),
    ]
    base.put(JourneyKeys.actionLabel, label)
    var spanAttributes = attributes
    spanAttributes[JourneyKeys.action] = .string(code)
    spanAttributes[JourneyKeys.actionId] = .string(id)
    if let label { spanAttributes[JourneyKeys.actionLabel] = .string(label) }
    instanceId = id
    self.attributes = Journey.merged(base, attributes)
    context = Journey.store.snapshot
    span = OtelFlutterBridge.shared.span(code, attributes: spanAttributes)
  }

  /// Ends the action: sets the outcome on the span, ends it and records a
  /// `journey.action` event with duration, linked to the span's trace.
  /// Screen, flow, user and session are those of when it began. Only the
  /// first call counts.
  ///
  /// `errorType` is a low-cardinality name of a technical failure
  /// (`URLError.timedOut`), never error text.
  public func end(_ outcome: JourneyOutcome = .completed, reason: (any JourneyReason)? = nil,
                  errorType: String? = nil) {
    guard ended.claim() else { return }
    span.setAttribute(key: JourneyKeys.outcome, value: outcome.rawValue)
    if let reason { span.setAttribute(key: JourneyKeys.reason, value: reason.code) }
    if let errorType { span.setAttribute(key: JourneyKeys.errorType, value: errorType) }
    if outcome == .failure { span.status = .error(description: errorType ?? "failure") }
    span.end()
    var attrs = attributes
    attrs[JourneyKeys.outcome] = .string(outcome.rawValue)
    attrs.put(JourneyKeys.reason, reason?.code)
    attrs.put(JourneyKeys.errorType, errorType)
    attrs[JourneyKeys.durationMs] = .int(Int(Date().timeIntervalSince(start) * 1000))
    Journey.record(JourneyKeys.actionEvent, attrs, span: span, time: start, context: context)
  }
}
