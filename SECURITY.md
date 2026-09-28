# Security policy

## Reporting a vulnerability

Please report privately through GitHub: **Security → Report a
vulnerability** on this repository. Do not open a public issue for security
problems, and do not include real personal data in reports.

You will get an answer within 5 business days. Fixes ship as a patch
release, with a changelog entry once users had time to update.

## What the library guarantees

| Question | Answer |
|---|---|
| Can personal data leave the device? | Only allowlisted attributes leave, and their values are scrubbed. Anything else is dropped. See `docs/specs/redaction.md` |
| Are there credentials in the app? | No. Point the app at your own collector; vendor tokens stay on the server |
| Where does it connect? | Only to the configured endpoint |
| Does it change system behaviour? | No swizzling, no hooks, no `URLProtocol`, no global overrides |
| Does it store anything on the device? | Not in 0.x. A future offline buffer (M7) will store only redacted data, size-limited |
| Dependencies? | Few and pinned: `dartastic_opentelemetry`, `http`, `fixnum`; OpenTelemetry Swift API/SDK on iOS |

Redaction on the device should not be the only barrier: repeat equivalent
rules in your collector.
