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
