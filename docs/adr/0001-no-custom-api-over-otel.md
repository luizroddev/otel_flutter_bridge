# 0001. No custom API over OpenTelemetry

Status: accepted

## Context
Teams adopting tracing already learn OpenTelemetry. A wrapper API would need
its own docs, would lag the SDK, and would lock the app into this library.

## Decision
The library configures and connects; the app uses the standard OTel API
(`OTel.tracer()` in Dart, `OpenTelemetry`/`Tracer` in Swift). The only
helpers are small, explicit functions for things the SDK does not do:
`invokeTraced` / `withTraceContext` for the platform channel, the dio
interceptor, `TracedURLSession`.

## Alternatives discarded
- A facade (`Telemetry.track(...)`): hides OTel, duplicates concepts.
- Auto-instrumentation of everything: conflicts with 0002.

## Consequences
Removing the library means replacing initialization only; spans created by
the app keep working with any OTel setup. Upstream SDK changes reach the app
directly, so the SDK version is pinned.
