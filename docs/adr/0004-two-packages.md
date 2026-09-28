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
