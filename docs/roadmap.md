# Roadmap

Each milestone has a gate: if its criterion is not met, the next one does
not start.

| Milestone | Deliverables | Done when | Status |
|---|---|---|---|
| M0 | Repository, two packages, CI, local Jaeger, specs for M2 and M3 | A test span from the example app shows up in Jaeger | Done |
| M1 | Performance spike on a physical device in Release; decision on where the pipeline lives | [ADR 0005](adr/0005-where-the-pipeline-lives.md) accepted with numbers | Open |
| M2 | Initialization, session, redaction, exporter, redaction test battery | Dart spans reach Jaeger with a session; no sensitive value passes the tests | Done |
| M3 | Native exporter, queue until Dart is ready, bridge receiver | Native spans, including those created before Dart is ready, arrive in the same session | Done |
| M4 | dio package, URLSession helper, `traceparent` on channel calls, demo backend | One trace with a Flutter action, a native call and an HTTP request, in the right hierarchy | Done |
| M5 | Real-world validation: physical devices, Release builds, runtime app protection tools | Acceptance criteria below met | Open |
| M6 | Collector example forwarding to a vendor backend, token kept server side, collector-side redaction | App trace linked to the backend trace in the vendor UI | Open |
| M7 | Offline buffer, flush on background, generic channel propagation, native Android bridge | No data lost in network-off and app-suspended tests | Open |
| M8 | 1.0 on pub.dev, complete docs, contributions upstream to the Dart SDK | First stable release | Open |

## M5 acceptance criteria

- One trace per instrumented flow with Flutter action, native call and HTTP
  in the right hierarchy.
- Native spans created before Flutter starts join the same session.
- No personal data in exported spans.
- The app behaves the same with the collector down.
- Runtime on/off switch works on both sides.
- Protected builds run with the library.
- No noticeable regression in startup time or frame rate.

Nothing from M7 goes in before the M5 gate.
