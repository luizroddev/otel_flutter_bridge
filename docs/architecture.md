# Architecture, in diagrams

How the library works inside an add-to-app Flutter app with an iOS host.
Each diagram links to the spec that defines it. The diagrams are Mermaid
(GitHub draws them); the text stays readable without rendering.

For the dashboard side (receiver, aggregator, storage, UI), see
[architecture.md](https://github.com/luizroddev/otel-journey-dashboard/blob/main/docs/architecture.md)
in `otel-journey-dashboard`. For adopting both in an existing system, see the
[adoption guide](adoption-guide.pt-BR.md) (Portuguese).

1. [Components](#1-components)
2. [Startup and the ready handshake](#2-startup-and-the-ready-handshake)
3. [One action, end to end](#3-one-action-end-to-end)
4. [One journey across Swift and Dart](#4-one-journey-across-swift-and-dart)
5. [The pipeline](#5-the-pipeline)
6. [Sessions](#6-sessions)
7. [Leaving the foreground](#7-leaving-the-foreground)
8. [Sending through the app's network stack](#8-sending-through-the-apps-network-stack)
9. [What a session looks like as data](#9-what-a-session-looks-like-as-data)

## 1. Components

Everything leaves the device from **one pipeline, in Dart**. The Swift side
records, queues until Dart is ready, and hands spans and events over the
platform channel ([native-bridge.md](specs/native-bridge.md),
[ADR 0005](adr/0005-where-the-pipeline-lives.md)).

```mermaid
flowchart LR
  subgraph app["App process"]
    direction LR
    subgraph dart["Flutter module (Dart)"]
      direction TB
      J["Journey<br/>screens · flows · actions · user"]
      SDK["OpenTelemetry Dart SDK<br/>spans"]
      ACP["AppContextSpanProcessor<br/>stamps screen, flow, user, session at start"]
      REC["JourneyRecorder<br/>events, batched every 2 s"]
      BSP["BatchSpanProcessor<br/>every 2 s"]
      NB["NativeBridge<br/>channel otel_flutter_bridge"]
      P["TelemetryPipeline<br/>session · redaction · queue"]
      T["Transport<br/>OTLP/HTTP or native export"]
      J --> REC
      J -->|"track: action span"| SDK
      SDK --> ACP
      SDK --> BSP --> P
      REC --> P
      NB -->|"native spans"| P
      NB -->|"native events"| REC
      P --> T
    end
    subgraph ios["iOS host (Swift)"]
      direction TB
      SJ["Journey (Swift)<br/>native screens and actions"]
      STORE["AppContextStore<br/>screen · open flow runs · user · host session"]
      OS["OpenTelemetry Swift SDK<br/>HTTPClientSpan · traced(channel:) · span()"]
      SQ["PendingSpanQueue<br/>up to 512 until Dart is ready"]
      EQ["PendingEventQueue<br/>up to 512 until Dart is ready"]
      EH["exportHandler<br/>the app's own network stack"]
      SJ --> STORE
      SJ --> EQ
      OS --> SQ
    end
  end
  SQ -->|"exportSpans"| NB
  EQ -->|"exportEvents"| NB
  STORE <-->|"journey: screen, user, flowStart, flowEnd, session"| NB
  T -->|"OTLP/HTTP protobuf<br/>/v1/traces · /v1/logs"| R[("Receiver<br/>collector · backend · dashboard")]
  T -.->|"export (sendThroughNative)"| EH
  EH -.-> R
```

| Piece | Where | Spec |
|---|---|---|
| `Journey` (Dart and Swift) | `lib/src/journey.dart`, `ios/Classes/Journey.swift` | [journey.md](specs/journey.md) |
| `TelemetryPipeline` | `lib/src/pipeline.dart` | [failure-and-limits.md](specs/failure-and-limits.md) |
| Redaction | `lib/src/redaction.dart` | [redaction.md](specs/redaction.md) |
| Session | `lib/src/session.dart` | [session.md](specs/session.md) |
| Channel, queues, shared state | `lib/src/native_bridge.dart`, `ios/Classes/` | [native-bridge.md](specs/native-bridge.md) |

## 2. Startup and the ready handshake

Native code can record before the Flutter engine runs. Nothing is lost: it
waits in bounded queues and joins the same session once Dart says it is
ready. Both sides then hold the same journey state.

```mermaid
sequenceDiagram
  autonumber
  participant Host as iOS host (AppDelegate)
  participant Swift as OtelFlutterBridge (Swift)
  participant Dart as OtelFlutterBridge (Dart)
  participant Pipe as Pipeline (Dart)

  Host->>Swift: start()
  Note over Swift: device and OS resource, network monitor, lifecycle observer
  opt The app owns the session
    Host->>Swift: setSession(id)
    Swift->>Swift: record session.start
  end
  Host->>Swift: native spans, Journey.screen(...)
  Note over Swift: queued, up to 512 spans and 512 events
  Host->>Dart: run the Flutter engine, main()
  Dart->>Dart: initialize(config)
  Dart->>Swift: ready {v: 1, enabled, maxBatchSize, journey: Dart state}
  Swift->>Swift: merge (native values win, Dart fills gaps, open runs from both stay)
  Swift-->>Dart: {journey: merged state, resource: device and OS}
  Dart->>Dart: adopt the state, follow the host session, add the device resource
  Swift->>Dart: exportSpans / exportEvents (what was queued)
  Dart->>Pipe: same path as Dart data
  Note over Swift,Dart: from here, every journey change is sent to the other side as it happens
```

## 3. One action, end to end

`Journey.track` makes one span for the action. The channel call, the native
code and the HTTP request become its children, and the backend continues the
same trace through `traceparent`
([native-bridge.md](specs/native-bridge.md#trace-context-across-the-channel)).
The journey event of the action carries the trace id, so the dashboard opens
the tree from the step.

```mermaid
sequenceDiagram
  autonumber
  actor User
  participant UI as Flutter screen
  participant J as Journey.track(confirmLogin)
  participant Ch as invokeTraced (Dart)
  participant Nat as traced(channel:) (Swift)
  participant Net as HTTPClientSpan (Swift)
  participant API as Backend API

  User->>UI: taps "Enter"
  UI->>J: track(confirmLogin, body)
  Note over J: span "confirmLogin" (screen, flow, run, user, session from now)
  J->>Ch: auth/login {args + _otel: traceparent, screen, flow, run}
  Ch->>Nat: client span auth/login
  Note over Nat: server span auth/login, current while the handler runs
  Nat->>Net: start(request)
  Net->>API: POST /v1/sessions + traceparent
  API-->>Net: 401
  Net-->>Nat: finish: error.type 401
  Nat-->>Ch: result(FlutterError invalid_password)
  Ch-->>J: throws, or a result the app maps
  J->>J: outcome failure, reason invalidPassword
  Note over J: span ends (status ERROR) and a journey.action event is recorded with duration, outcome, reason and the trace id
```

The resulting tree:

```mermaid
flowchart TD
  A["confirmLogin<br/>Dart · journey.action.name, outcome, reason"] --> B["auth/login<br/>Dart client span · rpc.*"]
  B --> C["auth/login<br/>Swift server span"]
  C --> D["POST<br/>Swift client span · http.*, url.path, network.connection.type"]
  D --> E["POST /v1/sessions<br/>backend span, when it propagates"]
```

## 4. One journey across Swift and Dart

The current screen, the open flow runs and the user are shared. Each side
applies a change locally and sends it to the other, which applies it
without sending it back. Either side can end a run; only the first end
counts ([journey.md](specs/journey.md#one-journey-across-both-sides)).

```mermaid
sequenceDiagram
  autonumber
  participant SN as Native screen (Swift)
  participant SS as AppContextStore (Swift)
  participant DS as Journey state (Dart)
  participant FS as Flutter screen (Dart)

  SN->>SS: Journey.screen(document)
  SS->>DS: journey {op: screen, code: document}
  SN->>SS: Journey.startFlow(login), run r1
  SS->>DS: journey {op: flowStart, run: r1}
  Note over SN,FS: native and Dart spans now carry journey.flow.instance_id = r1
  FS->>DS: Journey.screen(password)
  DS->>SS: journey {op: screen, code: password}
  FS->>DS: Journey.flowRun(login).end(success)
  Note over DS: records journey.flow.end for r1 with its duration
  DS->>SS: journey {op: flowEnd, instanceId: r1}
  Note over SS: r1 removed, a later end on the Swift side does nothing
```

## 5. The pipeline

Every span and event takes the same path before leaving the device
([redaction.md](specs/redaction.md),
[failure-and-limits.md](specs/failure-and-limits.md)).

```mermaid
flowchart TD
  DS["Dart spans<br/>(batched every 2 s)"] --> SUB
  NS["Native spans<br/>(from the channel)"] --> SUB
  DE["Dart journey events"] --> REC
  NE["Native journey events<br/>(from the channel)"] --> REC
  REC["JourneyRecorder<br/>one batch for both, every 2 s or 512 records"] --> SUBL
  SUB["Spans: session.id if missing · source · enrichers · resource gaps"] --> RED
  SUBL["Events: one OTLP logs request per batch"] --> RED
  RED["Redaction<br/>allowlist of keys · scrub values (never ids) · URL ids to {id} · truncate 256"] --> SPLIT
  SPLIT["Split: at most 512 per request"] --> Q
  Q["Queue: 32 requests, oldest dropped first"] --> TR{"Transport"}
  TR -->|"default"| HTTP["OTLP/HTTP, protobuf, optional gzip"]
  TR -->|"sendThroughNative"| NAT["export on the channel, sent by the app"]
  HTTP -->|"not 2xx"| DIAG["onDiagnostic: exportFailed<br/>(no retry yet)"]
  NAT -->|"false or timeout"| DIAG
  KS["Kill switch: setEnabled(false)"] -.->|"drops everything"| Q
```

## 6. Sessions

The library owns the session by default. With
`SessionConfig(fromHost: true)`, the native app owns it and calls
`setSession` ([session.md](specs/session.md)).

```mermaid
stateDiagram-v2
  [*] --> NoSession
  NoSession --> Active: first span or event, new id, session.start
  Active --> Active: activity
  Active --> Expired: 30 min without activity, or 4 h in total
  Expired --> Active: next activity, new id, session.start with session.previous_id
  Active --> NoSession: reset() on logout, the next one has no previous id
  note right of Active
    Host-owned session: the native app decides.
    setSession(id, previousId) records session.start,
    and Dart follows the id it receives.
  end note
```

## 7. Leaving the foreground

The last seconds before the user leaves are often the ones worth
investigating, so everything pending is sent before the app is suspended
([failure-and-limits.md](specs/failure-and-limits.md#leaving-the-foreground)).

```mermaid
sequenceDiagram
  autonumber
  participant OS as iOS
  participant Life as AppLifecycle (Swift)
  participant Swift as Queues (Swift)
  participant Dart as Dart

  OS->>Life: didEnterBackground
  Life->>Life: record device.app.lifecycle (ios.app.state background)
  Life->>OS: beginBackgroundTask
  Life->>Swift: flush native spans and events
  Swift->>Dart: exportSpans / exportEvents
  Life->>Dart: flush
  Dart->>Dart: flush the SDK batch, the events and the pipeline
  Dart-->>Life: done
  Life->>OS: endBackgroundTask (or after 10 s, or when iOS expires it)
  Note over Dart: Dart also flushes on hidden, paused and detached, for apps without the iOS side
```

## 8. Sending through the app's network stack

With `sendThroughNative`, the app's own client sends the telemetry
(certificate pinning, gateway headers, mutual TLS). The request is marked,
so the app's HTTP instrumentation never traces it
([native-bridge.md](specs/native-bridge.md#sending-through-the-apps-network-stack)).

```mermaid
sequenceDiagram
  autonumber
  participant Pipe as Pipeline (Dart)
  participant Plug as Plugin (Swift)
  participant H as exportHandler (the app)
  participant Cli as App API client
  participant Span as HTTPClientSpan
  participant Rcv as Receiver

  Pipe->>Plug: export {signal, url, headers, body}
  Plug->>H: TelemetryExport
  H->>H: export.urlRequest(), marked as telemetry
  H->>Cli: send(request)
  Cli->>Span: start(request)
  Span-->>Cli: isTelemetry, so no span and no traceparent
  Cli->>Rcv: POST /v1/traces (pinning, gateway headers)
  Rcv-->>Cli: 200
  Cli-->>H: success
  H-->>Plug: completion(true)
  Plug-->>Pipe: true
```

## 9. What a session looks like as data

```mermaid
classDiagram
  direction LR
  class Installation {
    app.installation.id
  }
  class Session {
    session.id
    session.previous_id
  }
  class FlowRun {
    journey.flow.name
    journey.flow.instance_id
    journey.flow.parent_instance_id
    journey.outcome
    journey.outcome_reason
  }
  class Action {
    journey.action.name
    journey.action.instance_id
    journey.outcome
    journey.duration_ms
  }
  class ScreenView {
    app.screen.name
  }
  class Trace {
    trace_id
    spans
  }
  Installation "1" --> "*" Session : has
  Session "1" --> "*" ScreenView : records
  Session "1" --> "*" FlowRun : records
  FlowRun "1" --> "*" FlowRun : nests
  FlowRun "1" --> "*" Action : contains
  Action "1" --> "0..1" Trace : measured actions
```

- Screen views, flow starts and ends, instant actions and lifecycle changes
  are **log records** with an event name.
- Measured actions are a **span** plus a `journey.action` event that
  carries the span's trace id.
- `user.id` is on everything after the login. `device.id` is stamped by the
  receiver, never sent by the app.
