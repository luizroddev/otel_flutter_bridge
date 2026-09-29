# otel_flutter_bridge

OpenTelemetry for **add-to-app** Flutter apps: Dart and native spans in one
trace, one session and one privacy-by-default pipeline, without swizzling.

```
Flutter tap ──► channel call ──► native code ──► native HTTP ──► backend
  (Dart span)    (traceparent)    (Swift span)    (traceparent)   (server span)
                         └──── all in one trace, one session.id ────┘
```

- **Uses the standard OTel API.** Built on
  [`dartastic_opentelemetry`](https://pub.dev/packages/dartastic_opentelemetry)
  (becoming the official Dart SDK) and OpenTelemetry Swift. No wrapper API.
- **One pipeline.** Native spans cross the platform channel in batches and go
  through the same redaction and destination as Dart spans. Spans created
  before Flutter starts wait in a bounded queue and join the same session.
- **Privacy by default.** Only allowlisted attributes leave the device;
  values are scrubbed (tokens, e-mails, document and card numbers, ids in
  URL paths). See [docs/specs/redaction.md](docs/specs/redaction.md).
- **Zero swizzling, zero hooks.** Only what the app calls explicitly is
  traced, so builds hardened by runtime app protection tools are not disturbed.
- **Never breaks the app.** Errors drop data, never throw.
- **Runtime kill switch** and configuration from remote config.

> Status: `0.1.0-dev`. Milestones M0 to M4 of the [roadmap](docs/roadmap.md)
> are implemented; see [CHANGELOG.md](CHANGELOG.md) and the limitations below.

## Try it in 5 minutes

Requirements: Flutter ≥ 3.27, Xcode with an iOS simulator, Docker.

```bash
make up         # Jaeger at http://localhost:16686, OTLP at :4318
make backend    # demo backend at :8080 (in another terminal)
make example-ios
```

In the app, tap the scenarios, then open the **Inspetor** tab: it shows,
live, every span that left the device, already redacted, as a tree. Copy a
trace id and search it in Jaeger to see the same trace, including the
backend spans.

Without Docker: `flutter run --dart-define=OTEL_ENDPOINT=` keeps data in
memory, and the inspector still works.

## Minimal usage

```dart
// main.dart
await OtelFlutterBridge.initialize(
  OtelBridgeConfig(
    serviceName: 'my-app',
    serviceVersion: '1.4.0',
    endpoint: Uri.parse('https://otel-collector.example.com'),
  ),
);

// Anywhere: the standard OpenTelemetry API.
final tracer = OTel.tracer();
final span = tracer.startSpan('checkout.confirm');
await tracer.withSpanAsync(span, () async {
  await myChannel.invokeTraced('pay', arguments: {'amount': 10}); // → native
  await dio.post('/orders');                                      // → backend
});
span.end();
```

```swift
// AppDelegate.application(_:didFinishLaunchingWithOptions:)
OtelFlutterBridge.shared.start()

// A channel handler: continues the Dart trace, ends when `result` is called.
channel.setMethodCallHandler(OtelFlutterBridge.shared.traced(channel: "app/native") { call, result in
  apiClient.request(Router.cart) { response in result(response.value) }  // HTTP becomes its child
})

// The app's single HTTP call site (Alamofire or anything else).
let call = HTTPClientSpan.start(urlRequest)
sessionManager.request(call.request).validate().responseData { response in
  call.finish(response: response.response, error: response.error) {
    completion(response)  // runs in the requester's trace
  }
}

// Native → Flutter, in the same trace (Dart: setTracedMethodCallHandler).
channel.invokeTraced("saldoAtualizado")
```

```dart
// package:http: wrap the app's single client and inject it.
final client = OtelHttpClient(http.Client(), propagateTo: {'api.example.com'});

// dio
final dio = Dio()..interceptors.add(OtelDioInterceptor(propagateTo: {'api.example.com'}));

// Bloc: one span per handled event; HTTP inside becomes its child.
on<LoadOrders>(tracedHandler('orders.load', _onLoadOrders));
```

## Repository

| Path | What |
|---|---|
| `packages/otel_flutter_bridge` | Core plugin: init, session, redaction, exporter, native bridge, channel propagation, `package:http` client, Bloc handler helper, inspector. iOS side in `ios/Classes` |
| `packages/otel_flutter_bridge_dio` | `dio` interceptor |
| `packages/otel_flutter_bridge/example` | POC app: scenarios + inspector |
| `tools/demo_backend` | Tiny server that continues the trace |
| `native_tests/ios` | `swift test` for the Foundation-only iOS core |
| `docs/specs` | The six specs (configuration, session, naming, redaction, failure, native bridge) |
| `docs/adr` | Architecture decision records |
| `docs/extension-points.md` | Every seam for app-specific customization |
| `docs/roadmap.md` | Milestones |
| `docs/integration-guide.pt-BR.md` | Step-by-step guide (Portuguese) to add the library to an existing add-to-app project |
| `docs/app-instrumentation-guide.pt-BR.md` | How to review an app (http, dio, Bloc, Cubit, channels) and instrument it, case by case (Portuguese) |

## Development

```bash
make test        # format check, analyze, Dart tests
make swift-test  # Swift core tests
make it          # integration test against local Jaeger (make up first)
```

CI runs all of the above plus an iOS simulator build of the example on every
pull request.

## Known limitations

- Android: Dart telemetry works; the native Android bridge is planned (M7).
- No offline buffer, retries or flush on background yet (M7). Data in memory
  is lost if the app is killed.
- Channel propagation is manual per call (`invokeTraced` Dart → native,
  `withTraceContext` / `runWithTraceContext` native → Dart); generic
  propagation is M7.
- Native crash capture is out of scope; keep your crash reporter.
- Traces only. Metrics and logs are out of scope for now.

## Compatibility

Dart ≥ 3.6, Flutter ≥ 3.27, iOS ≥ 13. `dartastic_opentelemetry` 0.11.0 and
OpenTelemetry Swift 2.5.1 are pinned exactly.

## License

Apache 2.0. See [LICENSE](LICENSE).
