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

  /// Current screen and flow of the host app, stamped on native spans when
  /// they start (`app.screen`, `app.flow`). Set `appContext.screen` when a
  /// native screen appears; Flutter screens are set from Dart.
  public let appContext = AppContextStore()

  public private(set) var tracerProvider: TracerProviderSdk?
  public private(set) var isStarted = false

  private init() {}

  /// Registers a tracer provider whose spans are sent to Dart.
  ///
  /// Extension points:
  /// - `resourceAttributes`: extra resource attributes for native spans
  ///   (they must be allowed by the Dart redaction config).
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
    queue.resource = FlutterChannelSpanExporter.attributes(resourceAttributes)
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

  /// A processor that stamps `app.screen` / `app.flow`. Add it to your own
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
  /// the screen and flow Dart sent along. Use it at the top of a method
  /// channel handler. To make requests inside it its children without
  /// passing the parent around, run that code in
  /// `OpenTelemetry.instance.contextProvider.withActiveSpan(span) { ... }`.
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
    }
    return span
  }

  /// Returns `arguments` with the trace context of `span` (default: the
  /// active span) and its screen and flow, for a call from native code to
  /// Dart. Dart continues the trace with `runWithTraceContext`.
  ///
  /// ```swift
  /// channel.invokeMethod("syncStatement",
  ///                      arguments: OtelFlutterBridge.shared.withTraceContext(["month": 5], span: span))
  /// ```
  public func withTraceContext(_ arguments: [String: Any]? = nil, span: Span? = nil) -> [String: Any] {
    var args = arguments ?? [:]
    guard let ctx = (span ?? OpenTelemetry.instance.contextProvider.activeSpan)?.context,
          ctx.isValid
    else { return args }
    let traceparent = TraceparentCodec.format(traceId: ctx.traceId.hexString,
                                              spanId: ctx.spanId.hexString,
                                              sampled: ctx.traceFlags.sampled)
    args[TraceparentCodec.channelContextKey] = TraceparentCodec.channelContext(
      traceparent: traceparent, app: appContext.values(forSpanId: ctx.spanId.hexString))
    return args
  }

  /// Sends pending spans now.
  public func flush() {
    _ = tracerProvider?.forceFlush()
    queue.flush()
  }
}
