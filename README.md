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
- **Journey out of the box.** Screens, flows and actions from plain enums,
  sent as OTLP log events and spans, so a dashboard can show what the user
  did in a session and open the trace of each step. See
  [docs/specs/journey.md](docs/specs/journey.md).
- **Runtime kill switch** and configuration from remote config.

> Status: `0.2.0-dev`. Milestones M0 to M4 of the [roadmap](docs/roadmap.md)
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

// The journey: your own enums, one line per thing worth seeing.
enum AppScreen with JourneyScreen { home, login, cart }
enum AppFlow with JourneyFlow { login, checkout }
enum AppAction with JourneyAction { chooseBiometric, confirmLogin, pay }

MaterialApp(navigatorObservers: [JourneyNavigatorObserver()]); // screens
final login = Journey.startFlow(AppFlow.login);
Journey.event(AppAction.chooseBiometric);                       // instant
final ok = await Journey.track(AppAction.confirmLogin, auth.login,   // span
    outcome: (ok) => ok ? JourneyOutcome.success : JourneyOutcome.failure);
login.end(ok ? JourneyOutcome.success : JourneyOutcome.failure);
Journey.setUser('u-42');                                        // opaque id

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
session.request(call.request).validate().responseData { response in
  call.finish(response: response.response, error: response.error) {
    completion(response)  // runs in the requester's trace
  }
}

// Native → Flutter, in the same trace (Dart: setTracedMethodCallHandler).
channel.invokeTraced("cartUpdated")

// Optional: send telemetry through the app's own network stack
// (Dart: OtelBridgeConfig(sendThroughNative: true)).
OtelFlutterBridge.shared.exportHandler = { export, completion in
  guard let request = export.urlRequest() else { return completion(false) }
  apiClient.send(request) { response in completion(response.isSuccess) }
}

// Native screens: the same journey API, shared with Dart.
enum AppScreen: String, JourneyScreen { case address }
enum AppFlow: String, JourneyFlow { case checkout }
Journey.screen(AppScreen.address)
Journey.flowRun(AppFlow.checkout)?.end(.success)   // a run Flutter started
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
| `docs/architecture.md` | How it works, in diagrams: components, startup, one action end to end, the journey shared by Swift and Dart, the pipeline, sessions, background, sending through the app's network stack |
| `docs/specs` | The specs (configuration, session, naming, redaction, failure, native bridge, journey) |
| `docs/adr` | Architecture decision records |
| `docs/extension-points.md` | Every seam for app-specific customization |
| `docs/roadmap.md` | Milestones |
| `docs/integration-guide.pt-BR.md` | Step-by-step guide (Portuguese) to add the library to an existing add-to-app project |
| `docs/app-instrumentation-guide.pt-BR.md` | How to review an app (http, dio, Bloc, Cubit, channels) and instrument it, case by case (Portuguese) |
| `docs/adoption-guide.pt-BR.md` | Adopting the library and the journey dashboard in another system: discovery, decisions, app, native, receiver, dashboard, volume, privacy, validation, rollout (Portuguese) |
| `docs/adoption-prompt.pt-BR.md` | A ready-to-use prompt for an AI coding agent to run that adoption phase by phase (Portuguese) |

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
- No offline buffer or retries yet (M7). Pending data is sent when the app
  leaves the foreground (on iOS inside a background task), but a request
  that fails is lost, and so is data in memory if the app crashes.
- Channel propagation is explicit: `invokeTraced` on the calling side and
  `traced(channel:)` (Swift) / `setTracedMethodCallHandler` (Dart) on the
  receiving side; generic propagation is M7.
- Native crash capture is out of scope; keep your crash reporter.
- Traces and journey events (OTLP logs). Metrics and free-form logs are out
  of scope.
- Destinations that take traces only (Jaeger) need
  `OtelBridgeConfig(exportLogs: false)`.

## Compatibility

Dart ≥ 3.6, Flutter ≥ 3.27, iOS ≥ 13. `dartastic_opentelemetry` 0.11.0 and
OpenTelemetry Swift 2.5.1 are pinned exactly.

## License

Apache 2.0. See [LICENSE](LICENSE). Commercial use is allowed; keep the
license text and its notices when you redistribute the code.

Every dependency uses a permissive license that allows commercial use:

| Dependency | License |
|---|---|
| `dartastic_opentelemetry` and its API | Apache 2.0 |
| OpenTelemetry Swift (API and SDK pods) | Apache 2.0 |
| `http`, `fixnum` and the other Dart packages they pull in | BSD-3-Clause, MIT or Apache 2.0 |
| `dio` (only in `otel_flutter_bridge_dio`) | MIT |

## Trademarks

OpenTelemetry is a trademark of The Linux Foundation. Flutter and Dart are
trademarks of Google LLC. This is an independent project: it is not
affiliated with, sponsored by or endorsed by the OpenTelemetry project, The
Linux Foundation or Google. The names describe what the library works with.
