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

| Prefix / key | Owner |
|---|---|
| OpenTelemetry semantic conventions (`http.*`, `url.*`, `server.*`, `rpc.*`, `error.*`, `exception.*`, `os.*`, `device.*`, `service.*`) | Standard |
| `session.id` | Library |
| `otel_flutter_bridge.*` | Library only (`otel_flutter_bridge.source` = `dart` / `native`) |
| `app.*` | The app using the library. Allowed by default, values scrubbed |

`rpc.system` for channel calls is `flutter_platform_channel`.

## Open questions

- Whether apps should get their own prefix instead of `app.`
  (configurable through `RedactionConfig.allowedPrefixes`).
