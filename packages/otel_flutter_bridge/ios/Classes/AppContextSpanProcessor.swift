import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Stamps `app.screen` / `app.flow` on native spans when they start.
///
/// - A span with a local parent copies the parent's values.
/// - A span continued from Dart (`startSpan(_:arguments:)`) takes the values
///   Dart sent with `traceparent`; `startSpan` stamps it.
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
    // Continued from Dart: startSpan(_:arguments:) stamps it with Dart's values.
    if parentContext?.isRemote == true { return }
    let values = store.valuesForNewSpan(parentSpanId: parentContext?.spanId.hexString)
    store.register(values, forSpanId: span.context.spanId.hexString)
    if let screen = values.screen { span.setAttribute(key: AppContextKeys.screen, value: screen) }
    if let flow = values.flow { span.setAttribute(key: AppContextKeys.flow, value: flow) }
  }

  public func onEnd(span: ReadableSpan) {}

  public func shutdown(explicitTimeout: TimeInterval?) {}

  public func forceFlush(timeout: TimeInterval?) {}
}
