# Spec: redaction

Status: draft · Implemented in `lib/src/redaction.dart` · Tests:
`test/redaction_test.dart`

Redaction runs **on the device, last, on the OTLP request itself**, right
before the transport. Dart spans and native spans take the same path, so
there is one set of rules. It is the part that most needs tests, because an
error here is a personal data leak.

## 1. Allowlist

An attribute (on resource, span, event or link) whose key is not allowed is
**dropped**, and `droppedAttributesCount` is incremented. It is never sent,
not even hashed.

Allowed by default (`defaultAllowedAttributes`): `service.name`,
`service.version`, `service.namespace`, `deployment.environment.name`,
`telemetry.sdk.*` (name, language, version), `os.type`, `os.name`,
`os.version`, `device.model.identifier`, `device.manufacturer`, `session.id`,
`http.request.method`, `http.response.status_code`, `http.route`,
`url.scheme`, `url.path`, `server.address`, `server.port`,
`network.protocol.version`, `error.type`, `exception.type`,
`exception.message`, `rpc.system`, `rpc.service`, `rpc.method`,
`otel_flutter_bridge.source`.

Plus every key under an allowed prefix (default: `app.`).

Deliberately **not** allowed: `url.full`, `url.query`, `http.request.header.*`,
`http.response.header.*`, `exception.stacktrace`, `user.*`, `enduser.*`,
`host.*`, `process.*`, `client.address`.

## 2. Scrubbing

Every allowed **string** value, span name, event name and status message is
scrubbed. Each match becomes `[REDACTED]`. Default rules, in order:

| Rule | Catches |
|---|---|
| `eyJ…\.…\.…` | JSON Web Tokens |
| `(bearer\|basic) <token>` | Authorization values |
| e-mail pattern | E-mail addresses |
| UUID pattern | UUIDs (often customer or account ids) |
| `?…` after a URL-like character | Query strings |
| 6+ digits, optionally split by one of ` .-/` | Document numbers (CPF, CNPJ), card numbers, phones, account numbers, IP addresses, long ids |

`url.path` and `http.route` are also normalized: a segment with a digit or
24+ characters becomes `{id}` (API versions like `v1` are kept), and query
and fragment are removed.

Values are truncated to `limits.maxAttributeValueLength` (256) after
scrubbing.

## 3. Types

- `bool`, `int`, `double`: kept (only reachable under allowed keys).
- Arrays: each element scrubbed; nested non-primitive elements dropped.
- Maps (`kvlist`) and bytes: dropped, because they cannot be checked key by key.

## 4. Never scrubbed

`trustedAttributes`: `session.id`, `otel_flutter_bridge.source` and the
resource attributes that describe the app and device (`service.*`,
`deployment.environment.name`, `telemetry.sdk.*`, `os.*`, `device.*`). They
come from configuration or the OS and scrubbing would corrupt them (a build
number is a digit run).

## 5. Extra rules through configuration

```dart
RedactionConfig(
  allowedAttributes: {'feature.flag'},   // extra exact keys
  allowedPrefixes: {'app.', 'poc.'},     // replaces the default {'app.'}
  extraPatterns: [r'ORD-\d{4}'],          // extra regular expressions
  useDefaultAllowlist: true,
  useDefaultScrubbers: true,
)
```

Invalid regular expressions are ignored (never throw at startup).

## 6. Second barrier

On-device redaction must not be the only protection. In production, repeat
equivalent rules in the collector (e.g. the OpenTelemetry Collector
`redaction` / `transform` processors).

## Open questions (maintainer decides)

- Is dropping all 6+ digit runs too aggressive for a given app (dates in
  free text, amounts)? Alternative: narrower patterns per document type.
- Should `server.address` be kept when it is an IP address? Today the IP is
  scrubbed.
- Should `exception.message` be allowed at all, given it is free text?
