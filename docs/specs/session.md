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
- Not derived from the user, the device, install id or time. The id alone
  cannot identify anyone.
- Stamped as `session.id` (OpenTelemetry session semantic convention):
  on Dart spans **when they start**, on journey events when they happen, and
  on native spans when they reach the pipeline. A session renewed before
  export never takes older Dart spans or events.
- Never scrubbed by redaction (it is library generated).

## `session.start`

Each new session records a `session.start` event (semantic conventions)
with its `session.id`. When it follows a session that expired in the same
app run, it also has `session.previous_id`, which links the two: the
conventions read it as the end of the previous session, so the library
sends no `session.end` (a session ending by inactivity is only noticed when
the next one starts). After `reset()` there is no previous id: the next
session may belong to another person. Sessions of one installation are
already linked by `app.installation.id`.

## Replacing the rules

Pass `sessionIdProvider:` to `initialize` to reuse a session the app already
has (for example the native app's own). The id must still not identify the
user. Call `Journey.sessionStarted(id, previousId: ...)` when it starts a
session, so receivers see `session.start`.

## Open questions

- Should a new session start when the app returns from a long background
  period, independently of the inactivity timer? (Needs the M7 lifecycle
  hooks.)
