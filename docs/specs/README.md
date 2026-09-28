# Specifications

Short specs written before the code of each part. They guide implementation
(including AI-assisted work) and are what anyone evaluating the library
reviews.

| Spec | Decides | Needed before |
|---|---|---|
| [configuration.md](configuration.md) | Every option, its default, how the app passes it | M2 |
| [session.md](session.md) | When a session starts and ends; how `session.id` is generated | M2 |
| [naming.md](naming.md) | `service.name`, span names, attribute prefixes | M2 |
| [redaction.md](redaction.md) | Allowlist, scrubbing rules, extra rules, what happens to the rest | M2 |
| [failure-and-limits.md](failure-and-limits.md) | Telemetry never breaks the app; queue sizes; what is dropped first | M2 |
| [native-bridge.md](native-bridge.md) | Native → Dart batch format and version, batch size, pre-ready queue | M3 |

**Status of all specs: draft.** The values below are the ones implemented and
tested; each "Open question" is a decision for the maintainer, not for code
review or AI.
