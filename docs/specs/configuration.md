# Spec: configuration

Status: draft · Implemented in `lib/src/config.dart`

## How the app passes configuration

1. In code: `OtelFlutterBridge.initialize(OtelBridgeConfig(...))`, once, in
   `main()`, before `runApp`.
2. From remote config: `OtelBridgeConfig.fromMap(map)`. Unknown keys are
   ignored and invalid values fall back to defaults; it never throws.
3. At runtime: `OtelFlutterBridge.setEnabled(bool)` switches Dart and native
   sides without a new release.

Native side: `OtelFlutterBridge.shared.start(...)` in
`application(_:didFinishLaunchingWithOptions:)`.

## Options

| Option | Map key | Default | Notes |
|---|---|---|---|
| `serviceName` | `serviceName` | required (`unknown_service` from map) | `service.name` |
| `serviceVersion` | `serviceVersion` | none | `service.version` |
| `deploymentEnvironment` | `deploymentEnvironment` | none | `deployment.environment.name` |
| `endpoint` | `endpoint` | required | `/v1/traces` appended when missing. The only host contacted |
| `enabled` | `enabled` | `true` | Master switch |
| `sampleRatio` | `sampleRatio` | `1.0` | Clamped to 0..1. Parent-based: children follow the root |
| `headers` | `headers` | `{}` | Never a vendor token (see SECURITY.md) |
| `resourceAttributes` | `resourceAttributes` | `{}` | Still subject to redaction |
| `redaction` | `redaction` | see [redaction.md](redaction.md) | |
| `session` | `session` | see [session.md](session.md) | |
| `limits` | `limits` | see [failure-and-limits.md](failure-and-limits.md) | |
| `exportTimeout` | `exportTimeoutMs` | 10 s | Per request |

## Extension points (code only, not remote)

`transport`, `enrichers`, `sessionIdProvider`, `onDiagnostic`,
`spanProcessors`. See [../extension-points.md](../extension-points.md).

## Open questions

- How often remote configuration should be re-read, and by whom (app or library).
- Whether `sampleRatio` changes should apply without restart (today: at init).
