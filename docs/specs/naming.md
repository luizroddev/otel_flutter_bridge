# Spec: naming

Status: draft · Constants in `lib/src/semantics.dart`

## Service

- `service.name`: one stable name per app, lowercase with dashes, from
  configuration. The same name for Dart and native spans (native spans get
  the Dart resource attributes when they lack them).
- `service.version`: the app version.

## Span names

Follow OpenTelemetry semantic conventions; names must be low cardinality and
never contain identifiers.

| Where | Name |
|---|---|
| HTTP client (dio and `TracedURLSession`) | `{METHOD}`, e.g. `GET` |
| Platform channel call | `{channel}/{method}`, e.g. `poc/native/loadCart` |
| App actions | `{area}.{action}`, e.g. `checkout.confirm` |
| Native work | `{Type}.{action}`, e.g. `NativeCart.load` |

Span names are scrubbed anyway (see [redaction.md](redaction.md)), but a
scrubbed name is a naming bug.

## Attributes

OpenTelemetry advises against custom names inside its namespaces (such as
`app.`) and recommends a prefix of your own for custom attributes. The
library follows that: its keys live under `journey.` and
`otel_flutter_bridge.`.

| Prefix / key | Owner |
|---|---|
| OpenTelemetry semantic conventions (`http.*`, `url.*`, `server.*`, `rpc.*`, `error.*`, `exception.*`, `os.*`, `device.*`, `service.*`, `session.*`, `app.screen.name`, `app.installation.id`) | Standard |
| `session.id`, `session.previous_id` | Standard keys, values from the library |
| `otel_flutter_bridge.*` | Library only (`otel_flutter_bridge.source` = `dart` / `native`) |
| `user.id`, `app.installation.id` | Standard keys, values from the app (`Journey.setUser`, `OtelBridgeConfig.installationId`); opaque ids, not scrubbed |
| `journey.*` | Library only: flow, action, outcome, reason, labels and durations; see [journey.md](journey.md). Always allowed |
| `app.*` (other than the standard keys) | The app using the library. Allowed by default, values scrubbed |

`app.` is allowed by default so an app's own attributes work without
configuration. A stricter app uses its own prefix (`shop.`) and adds it to
`RedactionConfig.allowedPrefixes`, as the conventions recommend.

Do not use a name both as a key and as a prefix of other keys
(`journey.outcome` and `journey.outcome.reason`): backends that nest dotted
names can reject one of them. Hence `journey.outcome_reason`.

`rpc.system` for channel calls is `flutter_platform_channel`.
