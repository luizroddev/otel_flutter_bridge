# Spec: failure and limits

Status: draft · Implemented in `lib/src/pipeline.dart`, `native_bridge.dart`,
`ios/Classes/Core/PendingSpanQueue.swift`

## Rule zero

**Telemetry never breaks the app.** Any error inside the library drops the
data involved and the app continues. No public method throws. Internal
problems are reported to `onDiagnostic` (kind + short technical detail,
never span data).

| Situation | Behaviour | Diagnostic |
|---|---|---|
| `initialize` fails | Bridge stays disabled; OTel API calls are no-ops | `initFailed` |
| Transport throws / non-2xx / timeout | Request dropped (no retry before M7) | `exportFailed` |
| Queue full | Oldest request dropped first | `queueFull` |
| Enricher or redaction throws | That submission dropped | `internalError` |
| Native batch with unknown version | Whole batch rejected | `nativeBatchRejected` |
| Malformed native span | That span skipped, others kept | `nativeBatchRejected` |
| Diagnostic listener throws | Ignored | — |
| No native side (tests, Android today) | Dart telemetry works normally | — |

## Limits

| Limit | Default | Where |
|---|---|---|
| `maxQueuedBatches` | 32 requests | Dart pipeline, waiting for the transport |
| `maxSpansPerExport` | 512 spans | One OTLP request |
| `maxNativeBatchSize` | 64 spans | One native → Dart channel message |
| `maxAttributeValueLength` | 256 chars | After scrubbing |
| Native pre-ready queue | 512 spans | `PendingSpanQueue(capacity:)` |
| SDK batch delay | 2 s Dart, 1 s native | `scheduleDelay` |

When a queue is full the **oldest** item is dropped first: recent data is
more useful for diagnosing what is happening now.

## Not yet (M7)

Offline buffer on disk, retries, flush on background. Until then, data in
memory is lost if the app is killed.

## Open questions

- Retry once on 429/503 before M7?
