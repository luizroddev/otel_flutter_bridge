# Changelog

All notable changes. Format based on Keep a Changelog; versions follow
semantic versioning. Package changelogs: `packages/*/CHANGELOG.md`.

## Unreleased

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
