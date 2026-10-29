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

## Leaving the foreground

Everything pending is sent when the app leaves the foreground, so the last
seconds before the user leaves (often the ones worth investigating) are
not lost:

- Dart: on `hidden`, `paused` and `detached` (not `inactive`, which also
  happens for a system dialog or the app switcher).
- iOS: on `didEnterBackground`, the native side holds a background task,
  hands its spans and events to Dart, and asks Dart to send everything
  (`flush` on the channel). The task ends when Dart replies, after 10 s,
  or when iOS says time is up. On `willTerminate`, a last best-effort
  flush.

A request that fails then is lost like any other.

## Not yet (M7)

Offline buffer on disk and retries. Until then, data that could not be
sent is lost, and so is what is in memory if the app is killed before it
leaves the foreground (a crash).

## Open questions

- Retry once on 429/503 before M7?
