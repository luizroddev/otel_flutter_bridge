# Spec: native → Dart bridge

Status: draft · Dart: `lib/src/native_batch.dart`, `native_bridge.dart` ·
iOS: `ios/Classes/`

## Channel

One `MethodChannel` named `otel_flutter_bridge`, standard codec.

| Direction | Method | Arguments | Reply |
|---|---|---|---|
| Dart → native | `ready` | `{v: 1, enabled: bool, maxBatchSize: int}` | `null`, or error `unsupported_version` |
| Dart → native | `setEnabled` | `{enabled: bool}` | `null` |
| native → Dart | `exportSpans` | batch (below) | `{accepted: int, rejected: int}` |

## Batch format, version 1

```
{
  "v": 1,
  "resource": { "<key>": <value>, ... },            // optional
  "spans": [
    {
      "traceId": "<32 lowercase hex>",               // required, not all zero
      "spanId": "<16 lowercase hex>",                // required, not all zero
      "parentSpanId": "<16 hex>",                    // optional
      "name": "<string>",                            // required
      "kind": "internal|server|client|producer|consumer",
      "startTimeUnixNano": <int>,                    // required
      "endTimeUnixNano": <int>,                      // required, >= start
      "status": { "code": "unset|ok|error", "message": "<string>" },
      "attributes": { "<key>": string|bool|int|double|[primitives] },
      "events": [ { "name", "timeUnixNano", "attributes" } ],
      "links":  [ { "traceId", "spanId", "attributes" } ],
      "scope":  { "name": "<string>", "version": "<string>" },
      "flags": <int>                                 // bit 0 = sampled
    }
  ]
}
```

Values that are maps are ignored. A span missing a required field is skipped
and counted in `rejected`; the rest of the batch is kept. A batch whose `v`
is not 1 is rejected as a whole. A future version 2 must be negotiated in
`ready` (Dart sends the version it understands; native refuses a mismatch).

## Dart side

Decodes to OTLP `ResourceSpans`, fills missing resource attributes from the
Dart resource (`service.name`, etc.), stamps `session.id` and
`otel_flutter_bridge.source = native`, and submits to the same pipeline as
Dart spans: same redaction, same destination.

## Native side (iOS)

- `FlutterChannelSpanExporter` (an OTel Swift `SpanExporter`) converts
  `SpanData` to the format above and hands it to `PendingSpanQueue`.
- **Until Dart is ready**, spans wait in `PendingSpanQueue` (bounded, 512,
  drop oldest). This covers spans created in `didFinishLaunching` before the
  Flutter engine runs; they reach Dart after `ready` and join the session.
- After `ready`, batches of at most `maxBatchSize` are sent on the main
  thread.
- `setEnabled(false)` discards what is pending and drops new spans.

## Trace context across the channel

Both directions use the same key in the call arguments (a map):

```
"_otel": {
  "traceparent": "<W3C value>",   // required
  "app.screen": "<string>",        // optional, the sender span's screen
  "app.flow": "<string>"           // optional, the sender span's flow
}
```

- **Dart → native**: `invokeTraced` / `withTraceContext` write it. Native
  reads it with `OtelFlutterBridge.shared.startSpan(_:arguments:)` (also
  stamps and registers the screen and flow, so native children copy them)
  or `extractContext(from:)`.
- **Native → Dart**: `OtelFlutterBridge.shared.withTraceContext(_:span:)`
  writes it. Dart continues with `runWithTraceContext(arguments, fn)`: spans
  started in `fn` are children of the native span and take its screen and
  flow unless they have a local parent.

Receivers ignore unknown keys, so older versions interoperate (without
screen and flow).

Helpers that write and read it:

| Side | Sends | Receives |
|---|---|---|
| Dart | `invokeTraced` (client span `channel/method`) | `setTracedMethodCallHandler` (server span `channel/method`) or `runWithTraceContext` |
| Swift | `FlutterMethodChannel.invokeTraced` (current span) | `traced(channel:_:)` (server span `channel/method`, ends on `result`) or `startSpan(_:arguments:)` |

On the Swift side the "current span" is `TraceContext.current`: a task-local
the bridge's helpers set (it survives `await` and child tasks), else
OpenTelemetry's active span (thread-bound). Propagation is explicit per call; generic propagation for
every message is M7.

## Sampling

Dart applies `sampleRatio` to native spans by trace id, with the same
`TraceIdRatioSampler` it uses for Dart roots. A trace sampled in Dart keeps
its native spans (same trace id, same decision); a trace that starts in
native code is kept or dropped at the same rate. Native code records
everything until then (the native sampler defaults to always on).

## If Dart never answers

Native keeps at most 512 spans and drops the oldest. Nothing blocks and no
memory grows unbounded.

## Open questions

- Should the native side time out waiting for `ready` and discard the queue?
- Background flush before iOS suspends the app (M7).
