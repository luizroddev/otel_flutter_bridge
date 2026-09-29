# Extension points

Everything app-specific stays in the app. These are the seams to customize
the library without forking it.

## Dart

| Seam | Where | Use it to |
|---|---|---|
| `OtelBridgeConfig` / `fromMap` | `initialize` | Names, endpoint, sampling, limits, remote config |
| `RedactionConfig` | `OtelBridgeConfig.redaction` | Extra allowed keys and prefixes, extra patterns |
| `TraceTransport` | `initialize(transport:)` | Send through the app's HTTP stack (pinning, proxy, auth); tee to another sink. `TeeTransport` and `InMemoryTransport` included |
| `SpanEnricher` | `initialize(enrichers:)` | Add attributes to every span (Dart and native) before redaction, e.g. `app.flow`, `app.tenant` |
| `SessionIdProvider` | `initialize(sessionIdProvider:)` | Reuse an existing, non-identifying session id |
| `DiagnosticListener` | `initialize(onDiagnostic:)` | Log internal problems in the app's logger |
| `spanProcessors` | `initialize(spanProcessors:)` | Extra OTel SDK processors (see spans **before** redaction: debug only) |
| `TelemetryPipeline.records` | `OtelFlutterBridge.pipeline` | Observe what was sent, after redaction |
| `TelemetryInspectorPage` / `View` | `package:otel_flutter_bridge/inspector.dart` | On-screen inspector for debug menus |
| `OtelDioInterceptor(filter:, enrich:, propagateTo:)` | dio package | Skip requests, add attributes, limit `traceparent` to own hosts |
| `invokeTraced` / `withTraceContext` | any `MethodChannel` | Continue the trace in native code |
| `OtelHttpClient(inner, filter:, enrich:, propagateTo:)` | the app's `http.Client` | Same as the dio interceptor, for `package:http` |
| `tracedHandler(name, handler, enrich:)` | Bloc `on<E>` or any two-argument callback | One span per handled event; children follow |

## iOS

| Seam | Use it to |
|---|---|
| `OtelFlutterBridge.shared.start(resourceAttributes:extraProcessors:sampler:registerGlobal:)` | Configure the native provider |
| `makeSpanProcessor()` | Add the bridge to a provider the app already has (`registerGlobal: false`) |
| `startSpan(_:arguments:)` / `extractContext(from:)` | Continue a Dart trace in a channel handler |
| `TracedURLSession.data(for:)` / `dataTask(with:)` and `propagateTo` | Explicit native HTTP tracing |
| `PendingSpanQueue` | Tune capacity or inspect `droppedCount` |

## Rule for any extension

Whatever an extension adds must pass redaction to leave the device. An
enricher adding `customer.id` does nothing: the key is not allowed. That is
the point.
