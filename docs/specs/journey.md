# Spec: journey

Status: draft · Implemented in `lib/src/journey.dart`

The journey is what the user did in a session: screens seen, flows started
and ended, actions taken and how each ended. It is plain OpenTelemetry:
**instant things are log records** (`event.name`), **things with a
duration are spans**, both sent over OTLP/HTTP. Any OTLP destination can
store them; the journey dashboard reads exactly this contract.

## API

```dart
enum AppScreen with JourneyScreen { home, login, cart('Carrinho') ... }
enum AppFlow with JourneyFlow { login, checkout }
enum AppAction with JourneyAction { chooseBiometric, confirmLogin, pay }

Journey.setUser('u-42');                    // after login; null on logout
Journey.screen(AppScreen.login);            // or JourneyNavigatorObserver
final run = Journey.startFlow(AppFlow.login);
Journey.event(AppAction.chooseBiometric);   // instant
final ok = await Journey.track(AppAction.confirmLogin, auth.login,
    outcome: (ok) => ok ? JourneyOutcome.success : JourneyOutcome.failure);
run.end(ok ? JourneyOutcome.success : JourneyOutcome.failure);
```

`code` defaults to the enum value name and must never change meaning once
shipped. `label` is optional readable text for the dashboard.

## Identities

| Key | Where | Meaning |
|---|---|---|
| `device.id` | resource | Installation or device id the app already has (`OtelBridgeConfig.deviceId`) |
| `session.id` | every span and event | The session, shared by Dart and native |
| `user.id` | every span and event, when set | Opaque user id (`Journey.setUser`); absent before login |
| `app.flow.instance_id` | spans and events inside a flow run | One run of a flow, such as one login attempt |
| `app.action.instance_id` | the action's span and event | One run of an action |
| `trace_id`, `span_id` | spans; events inside a span | The technical tree of an operation |

A session has many flow runs and traces. A flow run can span several
traces. No span stays open while the user is on a screen.

`session.id`, `user.id`, screen and flow are read **when the span or event
starts**: renewing the session or logging out later never changes what
already happened.

## Events (log records)

Every event has `severity_number` INFO, no body, `time_unix_nano` of when it
happened, and these attributes:

| Attribute | Always |
|---|---|
| `event.name` | yes |
| `session.id` | yes |
| `otel_flutter_bridge.source` | yes (`dart` or `native`) |
| `user.id` | when set |
| `app.screen.name` | when a screen is current |
| `app.flow.name`, `app.flow.instance_id` | when a flow run is current |

Events emitted inside an active span carry its `trace_id` and `span_id`;
events outside any span carry none (the dashboard shows them without a
tree).

| `event.name` | Extra attributes | When |
|---|---|---|
| `app.screen.view` | `app.screen.label` | `Journey.screen` / navigator observer |
| `app.flow.start` | `app.flow.label` | `Journey.startFlow` |
| `app.flow.end` | `app.flow.label`, `app.outcome`, `app.duration_ms` | `JourneyFlowRun.end` |
| `app.action` (instant) | `app.action.name`, `app.action.label`, `app.action.instance_id`, optional `app.outcome` | `Journey.event` |
| `app.action` (measured) | the above plus `app.outcome`, `app.duration_ms`, `error.type` on failure, and the action span's `trace_id` / `span_id` | `Journey.track` |

App attributes passed in `attributes:` are added as they are, under `app.`,
and go through redaction. Values: strings, booleans, numbers, enums (sent
as their name).

## Spans

`Journey.track` creates one span named after the action code, active while
the body runs, so HTTP and channel calls inside become its children. It has
`app.action.name`, `app.action.label`, `app.action.instance_id`,
`app.outcome` and the usual context attributes. On failure the status is
`ERROR`, with `error.type` when an exception was thrown (never its text).

Spans created with the plain OpenTelemetry API carry the same context
attributes (screen, flow, flow run, user, session) from when they started.

## Outcomes

`app.outcome` is one of:

| Value | Meaning |
|---|---|
| `success` | The app said it worked |
| `failure` | An exception, or the app said it did not work |
| `cancelled` | The user or the app cancelled |
| `completed` | The code finished; the app gave no business result |

A flow run with `app.flow.start` and no `app.flow.end` has **no
conclusion**: the app may have been closed, telemetry lost, or the end never
instrumented. Readers must not call it abandoned.

## Transport

- OTLP/HTTP, protobuf, `POST {endpoint}/v1/traces` and `{endpoint}/v1/logs`.
- Journey events are sent when `OtelBridgeConfig.exportLogs` is true (the
  default). Turn it off for destinations that only take traces.
- Events are batched with the same delay as spans and limited to
  `maxSpansPerExport` records per request. The kill switch drops them too.
- Instrumentation scope of events: `otel_flutter_bridge.journey`.

## Receivers

A receiver (a collector, a BFF, the journey dashboard) should:

- Overwrite `device.id` and `user.id` with what it authenticated, when it
  can, instead of trusting the app.
- Store `session.id`, `user.id`, `device.id`, `event.name`, the flow and
  action ids and the trace ids as indexed fields, and keep the rest of the
  record as received.
- Read `event.name` from the attribute (this library) or from the OTLP
  `event_name` field (newer SDKs).

## Open questions

- Native (Swift) journey API with the same contract.
- Whether events should follow the sampling of their trace.
