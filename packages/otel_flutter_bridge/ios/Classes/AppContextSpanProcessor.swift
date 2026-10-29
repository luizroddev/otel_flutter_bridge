import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Stamps `app.screen.name`, `journey.flow.name` and
/// `journey.flow.instance_id` on native spans when they start, with the
/// current `user.id` and, when the host owns the session, `session.id`.
///
/// - A span with a local parent copies the parent's screen and flow.
/// - A span continued from Dart (`startSpan(_:arguments:)`) takes the values
///   Dart sent with `traceparent`; `startSpan` stamps them.
/// - Any other span takes the current values of the store.
///
/// Installed by `OtelFlutterBridge.start`. When the app has its own provider,
/// add `makeAppContextProcessor()` to it.
public final class AppContextSpanProcessor: SpanProcessor {
  private let store: AppContextStore

  public init(store: AppContextStore) {
    self.store = store
  }

  public let isStartRequired = true
  public let isEndRequired = false

  public func onStart(parentContext: SpanContext?, span: ReadableSpan) {
    let now = store.snapshot
    if let user = now.userId { span.setAttribute(key: AppContextKeys.user, value: user) }
    if let session = now.sessionId { span.setAttribute(key: AppContextKeys.session, value: session) }
    // Continued from Dart: startSpan(_:arguments:) stamps it with Dart's values.
    if parentContext?.isRemote == true { return }
    let values = store.valuesForNewSpan(parentSpanId: parentContext?.spanId.hexString)
    store.register(values, forSpanId: span.context.spanId.hexString)
    if let screen = values.screen { span.setAttribute(key: AppContextKeys.screen, value: screen) }
    if let flow = values.flow { span.setAttribute(key: AppContextKeys.flow, value: flow) }
    if let flowId = values.flowId { span.setAttribute(key: AppContextKeys.flowId, value: flowId) }
  }

  public func onEnd(span: ReadableSpan) {}

  public func shutdown(explicitTimeout: TimeInterval?) {}

  public func forceFlush(timeout: TimeInterval?) {}
}
