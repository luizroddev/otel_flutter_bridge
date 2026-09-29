# Changelog

All notable changes. Format based on Keep a Changelog; versions follow
semantic versioning. Package changelogs: `packages/*/CHANGELOG.md`.

## Unreleased

## 0.1.0-dev.3

- `AppContext.screen` / `AppContext.flow`: stamped as `app.screen` /
  `app.flow` on every Dart span when it starts (installed by `initialize`).
  Child spans copy their local parent, so one trace never mixes screens.
  Both keys are always allowed by redaction; values are still scrubbed.
- `tracedHandler(nameOf:)`: one handler serving several operations (e.g. a
  login Bloc with biometric, password and reset) gets one span name per
  operation.
- iOS: `HTTPClientSpan.start` returns an `HTTPClientCall`; send
  `call.request` and call `call.finish(response:error:) { continuation }`.
  Works with any native HTTP stack (the app's API client over Alamofire,
  delegate-based sessions); the continuation runs in the requester's trace,
  so what the response triggers stays in it. `TracedURLSession` uses it.
  Same rules as Dart: `_OTHER` methods, `error.type` from the 4xx/5xx
  status first, then the error type.
- iOS: `traced(channel:_:)` wraps a channel handler (span `channel/method`,
  current while it runs, ends on `result`, `FlutterError` code as
  `error.type`); `FlutterMethodChannel.invokeTraced` calls Dart in the
  current trace.
- iOS: `TraceContext` keeps the current span in a Swift task-local as well
  as OpenTelemetry's thread-bound context, so it survives `await`;
  `bind(closure)` and `task { }` carry it through stored callbacks and
  async code.
- iOS: `OtelFlutterBridge.shared.span(_:)` starts a span whose parent is
  `TraceContext.current`, so manual spans stay in the trace inside `task { }`
  and bound callbacks (`tracer().spanBuilder` loses its parent after
  `await`).
- Docs: API map (recommended vs advanced) in the app guide; guides use the
  recommended APIs only.
- Dart: `MethodChannel.setTracedMethodCallHandler` continues native traces
  with a server span per call.
- Example app: channel handler with `traced`, scenario 9 (native → Flutter
  with `bind` and `invokeTraced`).
- iOS: `appContext.screen` / `.flow` stamped on native spans at start;
  children copy their parent; `startSpan(_:arguments:)` takes the screen and
  flow Dart sent, so one trace never mixes screens across the channel.
- Native → Dart propagation: `OtelFlutterBridge.shared.withTraceContext`
  (Swift) and `runWithTraceContext` (Dart). `invokeTraced` now also sends
  `app.screen` / `app.flow` in `_otel` (ignored by older native code).
- `sampleRatio` is applied to native spans by trace id, with the same
  sampler as Dart: traces that start in native code were always kept.
- Redaction spec: `exception.message` stays allowed (decision recorded).
- Docs: `SpanEnricher` runs at export time and is not suitable for the
  current screen or flow (the guides suggested it; fixed). App guide: the
  trace-per-action model, `AppContext` wiring, shared handlers, and the span
  link pattern for events caused by other events.

## 0.1.0-dev.2

- `OtelHttpClient`: `package:http` client wrapper with one client span per
  request and `traceparent` injection, same rules as the dio interceptor.
- `tracedHandler`: wraps Bloc event handlers (or any two-argument callback)
  in a span, without depending on `bloc`.
- Exceptions never export their text: `tracedHandler`, `OtelHttpClient` and
  `invokeTraced` record only `error.type` and error status, and
  `initialize` installs an SDK exception sanitizer that keeps only the type
  (`withSpanAsync`, `startActiveSpanAsync`). Previously `invokeTraced` and
  the SDK exported `exception.message` and the error text as status message.
- Outside debug mode, `initialize` turns off the SDK console log
  (`OTelLog`), which printed exception text to the device log.
- `error.type` uses fixed names for common types (`ClientException`,
  `PlatformException`, `TimeoutException`...) so obfuscated builds stay
  readable; `tracedHandler(errorType:)` maps app types.
- HTTP spans (http and dio) record non-standard methods as `_OTHER` with span
  name `HTTP`, per the semantic conventions.
- Example app: scenario 8, HTTP through `package:http`.
- Docs: app instrumentation guide (pt-BR) with the project review, the cases
  and the rollout; ADR 0004 amended with the rule for new packages.

## 0.1.0-dev.1

First development version (milestones M0–M4 of the [roadmap](docs/roadmap.md)).

- `OtelFlutterBridge.initialize` configuring the Dart OTel SDK from
  `OtelBridgeConfig` (code or remote map), with a runtime kill switch.
- Session manager with random, non-identifying `session.id`.
- Allowlist redaction and value scrubbing on the OTLP request, for Dart and
  native spans alike.
- OTLP/HTTP protobuf transport; pluggable `TraceTransport`.
- iOS: OpenTelemetry Swift exporter to Dart, queue until Dart is ready,
  channel trace context helpers, `TracedURLSession`.
- `invokeTraced` / `withTraceContext` for platform channels.
- `otel_flutter_bridge_dio` interceptor.
- In-app telemetry inspector.
- Example POC app, demo backend, local Jaeger, CI.
