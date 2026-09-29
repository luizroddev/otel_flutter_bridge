# 0004. Two packages: core and dio

Status: accepted

## Context
Not every app uses `dio`. A dependency the app does not need increases the
review surface and version conflicts.

## Decision
`otel_flutter_bridge` (core, iOS plugin) and `otel_flutter_bridge_dio`
(interceptor). The core does not depend on `dio`. Dependencies are pinned to
exact versions where they are part of the reviewed surface
(`dartastic_opentelemetry`, OTel Swift pods).

## Alternatives discarded
- One package with `dio` as dependency.
- One package per HTTP client up front (`http`, `chopper`...): add when needed.

## Consequences
Two versions to publish; they share the repository, CI and changelog cadence.

## Amendment: the rule for new integrations

A new package is created **only when the integration adds a dependency the
core does not already have**. Otherwise it goes in the core.

- `OtelHttpClient` (`package:http`) is in the core: the core already depends
  on `http` for the OTLP transport, so a separate package would only add a
  version to publish.
- `tracedHandler` (Bloc event handlers) is in the core: it wraps any
  two-argument callback and does not import `bloc`, which is a dev dependency
  used only by the tests. Apps that do not use Bloc get nothing new.
- Anything that needs `bloc` types at runtime (for example a `Bloc.add`
  override that captures the caller's context) stays in the app, or becomes
  its own package if it proves generic.
