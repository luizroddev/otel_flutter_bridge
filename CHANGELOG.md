# Changelog

All notable changes. Format based on Keep a Changelog; versions follow
semantic versioning. Package changelogs: `packages/*/CHANGELOG.md`.

## Unreleased

- `OtelHttpClient`: `package:http` client wrapper with one client span per
  request and `traceparent` injection, same rules as the dio interceptor.
- `tracedHandler`: wraps Bloc event handlers (or any two-argument callback)
  in a span, without depending on `bloc`.
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
