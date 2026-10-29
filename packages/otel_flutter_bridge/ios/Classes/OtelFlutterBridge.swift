import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Native entry point. Call `start` in `application(_:didFinishLaunchingWithOptions:)`,
/// before the Flutter engine runs, then use the standard OpenTelemetry Swift API.
///
/// Spans created before Dart is ready are kept in a bounded queue and sent
/// when Dart signals it is ready, so they join the same session.
public final class OtelFlutterBridge: @unchecked Sendable {
  public static let shared = OtelFlutterBridge()

  /// Native spans waiting for, or flowing to, Dart.
  public let queue = PendingSpanQueue()

  /// Native journey events (`Journey`) waiting for, or flowing to, Dart.
  public let events = PendingEventQueue()

  /// Where the user is (screen, open flow runs, user, and the host's
  /// session), shared with Dart and stamped on native spans when they
  /// start. Change it with `Journey`, which also records the events and
  /// tells Dart.
  public let appContext = AppContextStore()

  public private(set) var tracerProvider: TracerProviderSdk?
  public private(set) var isStarted = false

  private let journeyLock = NSLock()
  private var journeySink: (([String: Any]) -> Void)?
  private var dartFlush: ((@escaping () -> Void) -> Void)?
  private var _exportHandler: ((TelemetryExport, @escaping (Bool) -> Void) -> Void)?

  private init() {}

  /// Registers a tracer provider whose spans are sent to Dart, and sends
  /// what is pending when the app goes to the background (see
  /// `AppLifecycle`).
  ///
  /// The device model and OS (`device.model.identifier`, `os.version`, ...)
  /// are added to the resource of native and Dart data by default.
  ///
  /// Extension points:
  /// - `resourceAttributes`: extra resource attributes, which also win over
  ///   the defaults (they must be allowed by the Dart redaction config).
  /// - `extraProcessors`: more span processors, for example to log spans
  ///   while developing. They see spans before redaction.
  /// - `sampler`: defaults to always on; Dart sampling decisions are honoured
  ///   for spans parented by Dart through the channel.
  /// - `registerGlobal`: set false when the app already registers its own
  ///   provider; then add `spanProcessor` to it instead.
  @discardableResult
  public func start(resourceAttributes: [String: AttributeValue] = [:],
                    extraProcessors: [SpanProcessor] = [],
                    sampler: Sampler? = nil,
                    scheduleDelay: TimeInterval = 1,
                    registerGlobal: Bool = true) -> TracerProviderSdk {
    if let tracerProvider { return tracerProvider }
    var resource = DeviceInfo.resourceAttributes.mapValues { AttributeValue.string($0) }
    resourceAttributes.forEach { resource[$0.key] = $0.value }
    queue.resource = FlutterChannelSpanExporter.attributes(resource)
    NetworkStatus.shared.start()
    AppLifecycle.shared.start()
    var builder = TracerProviderBuilder()
      .add(spanProcessor: makeAppContextProcessor())
      .add(spanProcessor: makeSpanProcessor(scheduleDelay: scheduleDelay))
      .add(spanProcessors: extraProcessors)
    if let sampler { builder = builder.with(sampler: Samplers.parentBased(root: sampler)) }
    let provider = builder.build()
    if registerGlobal { OpenTelemetry.registerTracerProvider(tracerProvider: provider) }
    tracerProvider = provider
    isStarted = true
    return provider
  }

  /// A processor that sends spans to Dart. Add it to your own provider when
  /// you do not want `start` to create one.
  public func makeSpanProcessor(scheduleDelay: TimeInterval = 1) -> SpanProcessor {
    BatchSpanProcessor(spanExporter: FlutterChannelSpanExporter(queue: queue),
                       scheduleDelay: scheduleDelay, maxExportBatchSize: 64)
  }

  /// A processor that stamps `app.screen.name` / `journey.flow.name`. Add it to your own
  /// provider, before `makeSpanProcessor()`, when you do not use `start`.
  public func makeAppContextProcessor() -> SpanProcessor {
    AppContextSpanProcessor(store: appContext)
  }

  /// A tracer from the bridge's provider (or the global one).
  public func tracer(_ name: String = "otel_flutter_bridge.native", version: String? = nil) -> Tracer {
    let provider: TracerProvider = tracerProvider ?? OpenTelemetry.instance.tracerProvider
    return provider.get(instrumentationName: name, instrumentationVersion: version)
  }

  /// The span context Dart sent in platform channel arguments, if any.
  public func extractContext(from arguments: Any?) -> SpanContext? {
    guard let tp = TraceparentCodec.fromChannelArguments(arguments) else { return nil }
    return SpanContext.createFromRemoteParent(
      traceId: TraceId(fromHexString: tp.traceId),
      spanId: SpanId(fromHexString: tp.spanId),
      traceFlags: TraceFlags().settingIsSampled(tp.sampled),
      traceState: TraceState())
  }

  /// Starts a span that continues the trace Dart sent in `arguments`, with
  /// the screen and flow Dart sent along. Prefer `traced(channel:_:)`, which
  /// does this for a whole handler; use this for manual control, with
  /// `TraceContext.with(span) { ... }` so requests inside become children.
  public func startSpan(_ name: String, arguments: Any?, kind: SpanKind = .server,
                        attributes: [String: AttributeValue] = [:]) -> Span {
    let builder = tracer().spanBuilder(spanName: name).setSpanKind(spanKind: kind)
    let parent = extractContext(from: arguments)
    if let parent {
      builder.setParent(parent)
    } else {
      builder.setNoParent()
    }
    attributes.forEach { builder.setAttribute(key: $0.key, value: $0.value) }
    let span = builder.startSpan()
    if parent != nil {
      let values = TraceparentCodec.appContext(fromChannelArguments: arguments) ?? AppContextValues()
      appContext.register(values, forSpanId: span.context.spanId.hexString)
      if let screen = values.screen { span.setAttribute(key: AppContextKeys.screen, value: screen) }
      if let flow = values.flow { span.setAttribute(key: AppContextKeys.flow, value: flow) }
      if let flowId = values.flowId { span.setAttribute(key: AppContextKeys.flowId, value: flowId) }
    }
    return span
  }

  /// Tells the library the host app's current session, when the app owns
  /// it (its own rules start and renew it). Call it at launch, before the
  /// Flutter engine runs, and whenever the session changes; set
  /// `SessionConfig(fromHost: true)` in Dart so Dart follows it.
  ///
  /// A new id records a `session.start` event, with `previousId` when the
  /// new session continues one that expired (not after a logout: the next
  /// session may be another person's). Native spans and events get the
  /// session when they start. The id must be random and must not identify
  /// the user.
  public func setSession(id: String, previousId: String? = nil) {
    guard !id.isEmpty, appContext.setSession(id) else { return }
    var attributes: [String: BridgeAttributeValue] = [AppContextKeys.session: .string(id)]
    if let previousId, previousId != id { attributes[JourneyKeys.previousSession] = .string(previousId) }
    Journey.record(JourneyKeys.sessionStart, attributes)
    sendJourney(JourneySync.session(id))
  }

  /// Sends a change of the shared journey state to Dart once Dart is ready
  /// (before that, `ready` sends the whole state). From the main thread it
  /// goes right away, so Dart has it before the reply of a channel call
  /// made after it.
  func sendJourney(_ op: [String: Any]) {
    journeyLock.lock()
    let sink = journeySink
    journeyLock.unlock()
    guard let sink else { return }
    if Thread.isMainThread {
      sink(op)
    } else {
      DispatchQueue.main.async { sink(op) }
    }
  }

  func setJourneySink(_ sink: (([String: Any]) -> Void)?) {
    journeyLock.lock()
    journeySink = sink
    journeyLock.unlock()
  }

  /// Asks Dart to send everything pending; `done` runs when Dart replies,
  /// or right away when Dart is not connected. Call it on the main thread.
  func flushDart(_ done: @escaping () -> Void) {
    journeyLock.lock()
    let flush = dartFlush
    journeyLock.unlock()
    guard let flush else { return done() }
    flush(done)
  }

  func setDartFlush(_ flush: ((@escaping () -> Void) -> Void)?) {
    journeyLock.lock()
    dartFlush = flush
    journeyLock.unlock()
  }

  /// Returns `arguments` with the trace context of `span` (default: the
  /// current span, `TraceContext.current`) and its screen and flow, for a
  /// call from native code to Dart. Dart continues the trace with
  /// `setTracedMethodCallHandler` or `runWithTraceContext`. Prefer
  /// `channel.invokeTraced`, which does this.
  ///
  /// ```swift
  /// channel.invokeMethod("syncOrders",
  ///                      arguments: OtelFlutterBridge.shared.withTraceContext(["month": 5], span: span))
  /// ```
  public func withTraceContext(_ arguments: [String: Any]? = nil, span: Span? = nil) -> [String: Any] {
    var args = arguments ?? [:]
    guard let ctx = (span ?? TraceContext.current)?.context,
          ctx.isValid
    else { return args }
    let traceparent = TraceparentCodec.format(traceId: ctx.traceId.hexString,
                                              spanId: ctx.spanId.hexString,
                                              sampled: ctx.traceFlags.sampled)
    args[TraceparentCodec.channelContextKey] = TraceparentCodec.channelContext(
      traceparent: traceparent, app: appContext.values(forSpanId: ctx.spanId.hexString))
    return args
  }

  /// Sends telemetry through the app's own network stack, when Dart has
  /// `OtelBridgeConfig(sendThroughNative: true)`. Called with each OTLP
  /// request; call `completion(true)` when the server accepted it (2xx),
  /// `false` otherwise, once, from any thread. Without a handler, those
  /// requests fail.
  ///
  /// ```swift
  /// OtelFlutterBridge.shared.exportHandler = { export, completion in
  ///   guard let request = export.urlRequest() else { return completion(false) }
  ///   apiClient.send(request) { response in completion(response.isSuccess) }
  /// }
  /// ```
  ///
  /// `export.urlRequest()` is marked as telemetry, so `HTTPClientSpan`
  /// never traces it; mark requests you build yourself with
  /// `markAsTelemetry()`.
  public var exportHandler: ((TelemetryExport, @escaping (Bool) -> Void) -> Void)? {
    get {
      journeyLock.lock()
      defer { journeyLock.unlock() }
      return _exportHandler
    }
    set {
      journeyLock.lock()
      _exportHandler = newValue
      journeyLock.unlock()
    }
  }

  /// Hands pending native spans and events to Dart now. Dart sends them
  /// with its next export; when the app goes to the background this
  /// happens by itself, inside a background task.
  public func flush() {
    _ = tracerProvider?.forceFlush()
    queue.flush()
    events.flush()
  }
}
