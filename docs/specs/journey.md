# Spec: journey

Status: draft · Contract version 2 · Implemented in `lib/src/journey.dart`
(Dart) and `ios/Classes/Journey.swift` (Swift)

The journey is what the user did in a session: screens seen, flows started
and ended, actions taken and how each ended. It is plain OpenTelemetry:
**instant things are log records** with an event name, **things with a
duration are spans**, both sent over OTLP/HTTP. Any OTLP destination can
store them; the journey dashboard reads exactly this contract.

## Standards

- Events follow the OpenTelemetry logs data model: a log record with an
  event name is an event.
- Keys from the semantic conventions (v1.44.0) keep their names:
  `session.*`, `user.id`, `app.screen.name`, `app.installation.id`,
  `event.name`, `log.record.uid`, `error.type`. Most are still in
  Development status upstream, so a later release may rename some; this
  contract pins them.
- The library's own keys live under `journey.`. OpenTelemetry advises
  against custom names inside its namespaces (`app.` is one), because a
  future convention could take the same name with another meaning.

## API

```dart
enum AppScreen with JourneyScreen { home, login, cart('Carrinho') ... }
enum AppFlow with JourneyFlow { login, checkout }
enum AppAction with JourneyAction { chooseBiometric, confirmLogin, pay }
enum LoginReason with JourneyReason { invalidPassword, blockedAccount }

Journey.setUser('u-42');                    // after login; null on logout
Journey.screen(AppScreen.login);            // or JourneyNavigatorObserver
final run = Journey.startFlow(AppFlow.login);
Journey.event(AppAction.chooseBiometric);   // instant
final result = await Journey.track(AppAction.confirmLogin, auth.login,
    outcome: (r) => r.ok ? JourneyOutcome.success : JourneyOutcome.failure,
    reason: (r) => r.reason);               // a LoginReason, or null
run.end(JourneyOutcome.failure, reason: LoginReason.invalidPassword);
```

`code` defaults to the enum value name and must never change meaning once
shipped: renaming an enum value renames its code. Override `code` to keep
the old one. `label` is optional readable text for the dashboard.

### Native screens (Swift)

The same API exists in Swift, for screens and actions that are native.
Codes are the raw values of `String` enums:

```swift
enum AppScreen: String, JourneyScreen { case document }
enum AppFlow: String, JourneyFlow { case login }
enum AppAction: String, JourneyAction { case confirmLogin }
enum LoginReason: String, JourneyReason { case invalidPassword }

Journey.screen(AppScreen.document)
let run = Journey.startFlow(AppFlow.login)
let action = Journey.begin(AppAction.confirmLogin)  // span + event
TraceContext.with(action.span) {
  api.login { result in
    action.end(result.ok ? .success : .failure, reason: result.reason)
  }
}
Journey.flowRun(AppFlow.login)?.end(.success)
```

Native code is mostly callback based, so a measured action is `begin`
and `end` (an async `Journey.track` also exists). Swift events are recorded
where they happen, with the context of that moment, and reach the Dart
pipeline through the channel: same redaction, same destination.

### One journey across both sides

The current screen, the open flow runs and the user are **shared** by Swift
and Dart. Each side applies a change locally and sends it to the other
(`journey` on the channel, see [native-bridge.md](native-bridge.md)):

- A flow started on a native screen is the current flow of Flutter spans
  and events too, and the other way round.
- Either side can end a run (`Journey.flowRun(flow)?.end(...)`); only the
  first end counts, on both sides.
- `Journey.setUser` on either side sets `user.id` for both.

When both sides change the state at the same instant, the last change to
arrive wins; user-driven navigation never does this in practice.

## Identities

| Key | Where | Meaning |
|---|---|---|
| `app.installation.id` | resource | One installation of the app (`OtelBridgeConfig.installationId`; on iOS, `identifierForVendor`) |
| `session.id` | every span and event | The session, shared by Dart and native; the native app's own when it owns it ([session.md](session.md)) |
| `user.id` | every span and event, when set | Opaque user id (`Journey.setUser`); absent before login |
| `journey.flow.instance_id` | spans and events inside a flow run | One run of a flow, such as one login attempt |
| `journey.flow.parent_instance_id` | `journey.flow.start` / `journey.flow.end` of a nested run | The run that was current when this one started |
| `journey.action.instance_id` | the action's span and event | One run of an action |
| `trace_id`, `span_id` | spans; events inside a span | The technical tree of an operation |
| `log.record.uid` | every event | Unique id of the event, to drop resends |

The library never sends `device.id`. The semantic conventions advise against
it in consumer apps; a receiver that knows the device stamps it (see
[Receivers](#receivers)).

A session has many flow runs and traces. A flow run can span several
traces. No span stays open while the user is on a screen.

`session.id`, `user.id`, screen and flow are read **when the span or event
starts**: renewing the session or logging out later never changes what
already happened. For `Journey.track`, both the span and its event carry the
context of when the body started.

## Sessions

Each new session records a `session.start` event with `session.id` and,
when the session follows an expired one in the same app run,
`session.previous_id`. After `SessionManager.reset()` (logout) there is no
previous id: the next session may belong to someone else.

There is no `session.end`: a mobile session ends by inactivity, which is
only noticed when the next one starts. The conventions treat a
`session.start` with `session.previous_id` as the end of the previous
session. A custom `SessionIdProvider` records its own starts with
`Journey.sessionStarted`. See [session.md](session.md).

## Nested flows

A flow started while another is current is nested (a token activation
inside a login). It becomes the current flow; its start and end events carry
`journey.flow.parent_instance_id`; ending it makes the outer flow current
again. Starting a flow never ends the current one, and ending the outer flow
first leaves the inner one current.

## Events (log records)

Every event has `severity_number` INFO, no body, `time_unix_nano` of when it
happened, the OTLP `event_name` field, and these attributes:

| Attribute | Always |
|---|---|
| `event.name` | yes (same value as `event_name`, for older readers) |
| `log.record.uid` | yes |
| `session.id` | yes |
| `otel_flutter_bridge.source` | yes (`dart` or `native`) |
| `user.id` | when set |
| `app.screen.name` | when a screen is current |
| `journey.flow.name`, `journey.flow.instance_id` | when a flow run is current |

Events emitted inside an active span carry its `trace_id` and `span_id`;
events outside any span carry none (the dashboard shows them without a
tree).

| `event.name` | Extra attributes | When |
|---|---|---|
| `session.start` | `session.previous_id` when known | A new session starts |
| `journey.screen.view` | `journey.screen.label` | `Journey.screen` / navigator observer |
| `journey.flow.start` | `journey.flow.label`, `journey.flow.parent_instance_id` | `Journey.startFlow` |
| `journey.flow.end` | `journey.flow.label`, `journey.flow.parent_instance_id`, `journey.outcome`, `journey.outcome_reason`, `journey.duration_ms` | `JourneyFlowRun.end` |
| `journey.action` (instant) | `journey.action.name`, `journey.action.label`, `journey.action.instance_id`, optional `journey.outcome` and `journey.outcome_reason` | `Journey.event` |
| `journey.action` (measured) | the above plus `journey.outcome`, `journey.duration_ms`, `error.type` on failure, and the action span's `trace_id` / `span_id` | `Journey.track` |
| `device.app.lifecycle` | `ios.app.state`: `background`, `foreground` or `terminate` | iOS: the app goes to the background, comes back or is terminated |

App attributes passed in `attributes:` are added as they are and go through
redaction: their keys must be allowed (by default, anything under `app.`).
Never add keys under `journey.`. Values: strings, booleans, numbers, enums
(sent as their name).

## Spans

`Journey.track` creates one span named after the action code, active while
the body runs, so HTTP and channel calls inside become its children. It has
`journey.action.name`, `journey.action.label`, `journey.action.instance_id`,
`journey.outcome`, `journey.outcome_reason` when given, and the usual
context attributes. On failure the status is `ERROR`, with `error.type`
when an exception was thrown (never its text).

Spans created with the plain OpenTelemetry API carry the same context
attributes (screen, flow, flow run, user, session) from when they started,
on both sides.

`error.type` of a native network failure keeps the `URLError` code
(`URLError.timedOut`, `URLError.notConnectedToInternet`,
`URLError.serverCertificateUntrusted`), so a timeout, no connection and a
failed certificate check are told apart. Native HTTP spans also carry
`network.connection.type` (`wifi`, `cell`, `unavailable`).

## Outcomes and reasons

`journey.outcome` is one of:

| Value | Meaning |
|---|---|
| `success` | The app said it worked |
| `failure` | An exception, or the app said it did not work |
| `cancelled` | The user or the app cancelled |
| `completed` | The code finished; the app gave no business result |

`journey.outcome_reason` says why, as a code from a fixed list the app
declares (`JourneyReason`): `invalidPassword`, `blockedAccount`. It answers
"which failures, how many" without free text. Technical failures keep
`error.type`; both can be present.

A flow run with `journey.flow.start` and no `journey.flow.end` has **no
conclusion**: the app may have been closed, telemetry lost, or the end never
instrumented. Readers must not call it abandoned.

## Transport

- OTLP/HTTP, protobuf, `POST {endpoint}/v1/traces` and `{endpoint}/v1/logs`,
  gzip compressed with `OtelBridgeConfig.gzip`. With `sendThroughNative`,
  the native app sends them through its own network stack.
- Journey events are sent when `OtelBridgeConfig.exportLogs` is true (the
  default). Turn it off for destinations that only take traces.
- Events are batched with the same delay as spans and limited to
  `maxSpansPerExport` records per request. The kill switch drops them too.
- Instrumentation scope of events: `otel_flutter_bridge.journey`.

## Receivers

A receiver is whatever takes these requests before storage: a collector, a
backend for the app, the journey dashboard.

### Accept

A receiver with its own allowlist must let these through, or the journey
breaks in silence.

| What | Values |
|---|---|
| Resource attributes | `service.name`, `service.version`, `deployment.environment.name`, `os.type`, `os.name`, `os.version`, `device.model.identifier`, `device.manufacturer`, `app.installation.id`, `telemetry.sdk.*` |
| Event names | `session.start`, `journey.screen.view`, `journey.flow.start`, `journey.flow.end`, `journey.action`, `device.app.lifecycle` |
| Event and span attributes | everything in the tables above (including `ios.app.state`), plus the HTTP, RPC, `network.connection.type` and error keys of [redaction.md](redaction.md) and the app's own keys |
| Span names | action codes chosen by the app, `{METHOD}` for HTTP, `{channel}/{method}` for channel calls. Match them with a pattern (for example `^[A-Za-z0-9_.:/-]{1,128}$`) rather than a fixed list, or every new action is rejected |

### Never scrub ids

Ids are random hex: about half of all random 32-hex ids contain a run of 6
or more digits, and about 1 in 20 a run of 11 or more. A rule that scrubs
digit runs (documents, phones) corrupts them, and the journey no longer
links. Do not scrub the values of `session.id`, `session.previous_id`,
`user.id`, `app.installation.id`, `log.record.uid`,
`journey.flow.instance_id`, `journey.flow.parent_instance_id`,
`journey.action.instance_id`, nor `trace_id` / `span_id`.

### Stamp identity

- Stamp `device.id` from what the receiver authenticated (a device header
  it already checks), never from the payload.
- Overwrite `user.id` with the authenticated user when it knows one, or
  store a keyed hash of it as `user.hash`. A plain hash of a document
  number is not protection: the space of valid numbers is small enough to
  hash all of them.

### Store

- Store `session.id`, `user.id`, `device.id`, `app.installation.id`,
  `event.name`, the flow and action ids and the trace ids as indexed
  fields, and keep the rest of the record as received.
- Read the OTLP `event_name` field, falling back to the `event.name`
  attribute.
- Deduplicate events by `log.record.uid` and spans by trace and span id:
  OTLP clients resend after a timeout.

## Changes from version 1

- The library's keys and event names moved from `app.` to `journey.`
  (`app.flow.name` is now `journey.flow.name`, `app.action` is now
  `journey.action`, and so on). `app.screen.name` stays: it is a semantic
  convention.
- `device.id` is no longer sent; `app.installation.id` is.
- New: `session.start` with `session.previous_id`,
  `journey.outcome_reason`.

## Open questions

- Whether events should follow the sampling of their trace.
- Native Android journey API (no native Android bridge yet).
