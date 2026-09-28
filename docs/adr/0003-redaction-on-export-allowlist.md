# 0003. Redaction on export, with an allowlist

Status: accepted

## Context
In an app that handles personal data, "no personal data leaves the device"
must be easy to
prove. Denylists fail open: any new attribute leaks until someone notices.
Redacting at span creation misses attributes set later and native spans.

## Decision
Redaction runs last, on the OTLP request, right before the transport. Only
allowlisted keys pass; their string values are scrubbed by patterns. Dart and
native spans take the same path. See `docs/specs/redaction.md`.

## Alternatives discarded
- Denylist of known sensitive keys.
- Redaction in a `SpanProcessor.onEnd` (spans are immutable after end).
- Collector-only redaction (data already left the device).

## Consequences
New attributes are invisible until allowed, which is intended. Rules are
testable in isolation (the redaction test battery). The collector still
repeats redaction as a second barrier (M6).
