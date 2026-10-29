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

## Amendment: the journey API

`Journey` (Dart and Swift) is a small API of the library's own: screens,
flows, actions, reasons and the user. It is allowed because it is not a
facade over tracing:

- It records what the SDK has no concept of (a screen view, the run of a
  flow across screens and runtimes, the business outcome of an action) and
  emits only standard OpenTelemetry: log records with an event name, and a
  span for a measured action. Any OTLP destination stores them; nothing
  needs this library to read them ([specs/journey.md](../specs/journey.md)).
- Tracing stays on the standard API. `Journey.track` / `Journey.begin` start
  a plain span that the app's own spans and HTTP calls join as children.
- Its vocabulary is the app's own enums, so a typo is a compile error and
  the list of screens and actions can be reviewed in one file.

Removing the library now also means replacing the `Journey` calls: about
one line per screen, flow and action, in the places the app chose.
