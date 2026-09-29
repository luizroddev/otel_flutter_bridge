# Extension points

Everything app-specific stays in the app. These are the seams to customize
the library without forking it.

## Dart

| Seam | Where | Use it to |
|---|---|---|
| `OtelBridgeConfig` / `fromMap` | `initialize` | Names, endpoint, sampling, limits, remote config |
| `RedactionConfig` | `OtelBridgeConfig.redaction` | Extra allowed keys and prefixes, extra patterns |
| `TraceTransport` | `initialize(transport:)` | Send through the app's HTTP stack (pinning, proxy, auth); tee to another sink. `TeeTransport` and `InMemoryTransport` included |
| `SpanEnricher` | `initialize(enrichers:)` | Add attributes to every span (Dart and native) before redaction, at export time: values fixed for the session, e.g. `app.tenant` |
| `AppContext.screen` / `.flow` | anywhere (navigation) | Stamp `app.screen` / `app.flow` on every Dart span when it starts; children copy their parent |
| `SessionIdProvider` | `initialize(sessionIdProvider:)` | Reuse an existing, non-identifying session id |
| `DiagnosticListener` | `initialize(onDiagnostic:)` | Log internal problems in the app's logger |
| `spanProcessors` | `initialize(spanProcessors:)` | Extra OTel SDK processors (see spans **before** redaction: debug only) |
| `TelemetryPipeline.records` | `OtelFlutterBridge.pipeline` | Observe what was sent, after redaction |
| `TelemetryInspectorPage` / `View` | `package:otel_flutter_bridge/inspector.dart` | On-screen inspector for debug menus |
| `OtelDioInterceptor(filter:, enrich:, propagateTo:)` | dio package | Skip requests, add attributes, limit `traceparent` to own hosts |
| `invokeTraced` / `withTraceContext` | any `MethodChannel` | Continue the trace in native code (carries screen and flow) |
| `setTracedMethodCallHandler` / `runWithTraceContext(arguments, fn)` | a Dart channel handler native code calls | Continue a native trace in Dart (server span `channel/method`) |
| `OtelHttpClient(inner, filter:, enrich:, propagateTo:)` | the app's `http.Client` | Same as the dio interceptor, for `package:http` |
| `tracedHandler(name, handler, nameOf:, enrich:, errorType:)` | Bloc `on<E>` or any two-argument callback | One span per handled event; children follow |

## iOS

| Seam | Use it to |
|---|---|
| `OtelFlutterBridge.shared.start(resourceAttributes:extraProcessors:sampler:registerGlobal:)` | Configure the native provider |
| `makeSpanProcessor()` + `makeAppContextProcessor()` | Add the bridge to a provider the app already has (`registerGlobal: false`) |
| `traced(channel:_:)` | Wrap a channel handler: continues the Dart trace, current while it runs, ends on `result` |
| `FlutterMethodChannel.invokeTraced` | Call Dart in the current trace (Dart: `setTracedMethodCallHandler`) |
| `startSpan(_:arguments:)` / `extractContext(from:)` / `withTraceContext(_:span:)` | Manual control of the same |
| `HTTPClientSpan.start` → `call.finish(response:error:) { }` and `propagateTo` | One client span per request for any HTTP stack; the continuation runs in the requester's trace |
| `bind(closure)` / `task { }` / `TraceContext.with` / `.current` | Carry the current span through stored callbacks and `async` code |
| `appContext.screen` / `.flow` | Stamp `app.screen` / `app.flow` on native spans at start |
| `TracedURLSession.data(for:)` / `dataTask(with:)` | The same, for plain `URLSession` calls |
| `PendingSpanQueue` | Tune capacity or inspect `droppedCount` |

## Rule for any extension

Whatever an extension adds must pass redaction to leave the device. An
enricher adding `customer.id` does nothing: the key is not allowed. That is
the point.
