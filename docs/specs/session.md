# Spec: session

Status: draft · Implemented in `lib/src/session.dart`

## Rules

- A session starts on the first span after `initialize`.
- It ends after **30 minutes without spans** (`inactivityTimeout`) or after
  **4 hours** in total (`maxDuration`), whichever comes first. The next span
  starts a new session.
- "Activity" is a batch reaching the pipeline (Dart or native), not user
  input. Granularity is therefore the export delay (2 s by default).
- `SessionManager.reset()` ends the session explicitly (e.g. on logout).

## `session.id`

- 128 bits from `Random.secure()`, written as 32 lowercase hex characters.
- Not derived from the user, the device, install id or time. It cannot
  identify anyone and cannot be linked across sessions.
- Stamped on every span, Dart and native, as `session.id`
  (OpenTelemetry session semantic convention), at export time.
- Never scrubbed by redaction (it is library generated).

## Replacing the rules

Pass `sessionIdProvider:` to `initialize` to reuse a session the app already
has. The id must still not identify the user.

## Open questions

- Should a new session start when the app returns from a long background
  period, independently of the inactivity timer? (Needs the M7 lifecycle
  hooks.)
