/// Attribute keys and names shared by the Dart and native sides.
/// See `docs/specs/naming.md` and `docs/specs/journey.md`.
///
/// Keys from the OpenTelemetry semantic conventions keep their names. The
/// library's own journey keys live under `journey.`: OpenTelemetry advises
/// against custom names inside its namespaces, such as `app.`.
library;

/// `session.id`, from the OpenTelemetry session semantic conventions.
const sessionIdKey = 'session.id';

/// `session.previous_id`, from the OpenTelemetry session semantic
/// conventions: on `session.start`, the session this one follows.
const sessionPreviousIdKey = 'session.previous_id';

/// `user.id`, from the OpenTelemetry user semantic conventions. Set with
/// `Journey.setUser`; must be an opaque id, never an e-mail or a document.
const userIdKey = 'user.id';

/// `app.installation.id`, from the OpenTelemetry app semantic conventions:
/// one installation of the app. A resource attribute, set with
/// `OtelBridgeConfig.installationId`.
const appInstallationIdKey = 'app.installation.id';

/// `event.name` of a log record, from the OpenTelemetry event conventions.
/// Also written to the OTLP `event_name` field.
const eventNameKey = 'event.name';

/// `log.record.uid`, from the OpenTelemetry log conventions: a unique id of
/// each journey event, so receivers can drop resends. Random, 32 hex
/// characters.
const logRecordUidKey = 'log.record.uid';

/// The screen the user was on when a span or event started
/// (`app.screen.name`, OpenTelemetry semantic conventions). See `AppContext`.
const appScreenKey = 'app.screen.name';

/// Readable label of a screen, when the app gives one.
const journeyScreenLabelKey = 'journey.screen.label';

/// The flow (journey across screens) the user was in. See `AppContext`.
const journeyFlowKey = 'journey.flow.name';

/// Readable label of a flow, when the app gives one.
const journeyFlowLabelKey = 'journey.flow.label';

/// One run of a flow, such as one login attempt. Random, 32 hex characters.
const journeyFlowInstanceKey = 'journey.flow.instance_id';

/// The run of the flow that was current when this one started, on
/// `journey.flow.start` / `journey.flow.end` of a nested flow.
const journeyFlowParentInstanceKey = 'journey.flow.parent_instance_id';

/// The action of a journey step, such as `confirmLogin`.
const journeyActionKey = 'journey.action.name';

/// Readable label of an action, when the app gives one.
const journeyActionLabelKey = 'journey.action.label';

/// One run of an action. Random, 32 hex characters.
const journeyActionInstanceKey = 'journey.action.instance_id';

/// How an action or flow ended: `success`, `failure`, `cancelled` or
/// `completed`. See `JourneyOutcome`.
const journeyOutcomeKey = 'journey.outcome';

/// Why it ended that way, as a fixed code from the app, such as
/// `invalidPassword`. See `JourneyReason`.
const journeyOutcomeReasonKey = 'journey.outcome_reason';

/// Duration of an action or flow, in milliseconds.
const journeyDurationKey = 'journey.duration_ms';

/// `event.name` of a screen view.
const eventScreenView = 'journey.screen.view';

/// `event.name` of an action, instant or measured.
const eventAction = 'journey.action';

/// `event.name` of the start of a flow run.
const eventFlowStart = 'journey.flow.start';

/// `event.name` of the end of a flow run.
const eventFlowEnd = 'journey.flow.end';

/// `event.name` of the start of a session, from the OpenTelemetry session
/// semantic conventions.
const eventSessionStart = 'session.start';

/// Instrumentation scope of journey events.
const journeyScopeName = 'otel_flutter_bridge.journey';

/// Where a span was created: [bridgeSourceDart] or [bridgeSourceNative].
const bridgeSourceKey = 'otel_flutter_bridge.source';

/// Value of [bridgeSourceKey] for spans created in Dart.
const bridgeSourceDart = 'dart';

/// Value of [bridgeSourceKey] for spans created in native code.
const bridgeSourceNative = 'native';

/// Name of the method channel between Dart and native code.
const bridgeChannelName = 'otel_flutter_bridge';

/// Key under which trace context travels inside method channel arguments.
const channelContextKey = '_otel';

/// `rpc.system` value for calls made through a Flutter platform channel.
const rpcSystemFlutterChannel = 'flutter_platform_channel';

/// Version of the native to Dart batch format. See
/// `docs/specs/native-bridge.md`.
const nativeBatchFormatVersion = 1;

/// `network.connection.type`, from the OpenTelemetry network conventions:
/// `wifi`, `cell`, `wired`, `unavailable` or `unknown`. Stamped by the native
/// side on its HTTP client spans.
const networkConnectionTypeKey = 'network.connection.type';
