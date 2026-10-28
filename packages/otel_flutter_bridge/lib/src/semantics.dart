/// Attribute keys and names shared by the Dart and native sides.
/// See `docs/specs/naming.md` and `docs/specs/journey.md`.
library;

/// `session.id`, from the OpenTelemetry session semantic conventions.
const sessionIdKey = 'session.id';

/// `user.id`, from the OpenTelemetry user semantic conventions. Set with
/// `Journey.setUser`; must be an opaque id, never an e-mail or a document.
const userIdKey = 'user.id';

/// `device.id`, from the OpenTelemetry device semantic conventions. A
/// resource attribute, set with `OtelBridgeConfig.deviceId`.
const deviceIdKey = 'device.id';

/// `event.name` of a log record, from the OpenTelemetry event conventions.
const eventNameKey = 'event.name';

/// The screen the user was on when a span or event started
/// (`app.screen.name`, OpenTelemetry semantic conventions). See `AppContext`.
const appScreenKey = 'app.screen.name';

/// Readable label of a screen, when the app gives one.
const appScreenLabelKey = 'app.screen.label';

/// The flow (journey across screens) the user was in. See `AppContext`.
const appFlowKey = 'app.flow.name';

/// Readable label of a flow, when the app gives one.
const appFlowLabelKey = 'app.flow.label';

/// One run of a flow, such as one login attempt. Random, 32 hex characters.
const appFlowInstanceKey = 'app.flow.instance_id';

/// The action of a journey step, such as `confirmLogin`.
const appActionKey = 'app.action.name';

/// Readable label of an action, when the app gives one.
const appActionLabelKey = 'app.action.label';

/// One run of an action. Random, 32 hex characters.
const appActionInstanceKey = 'app.action.instance_id';

/// How an action or flow ended: `success`, `failure`, `cancelled` or
/// `completed`. See `JourneyOutcome`.
const appOutcomeKey = 'app.outcome';

/// Duration of an action or flow, in milliseconds.
const appDurationKey = 'app.duration_ms';

/// `event.name` of a screen view.
const eventScreenView = 'app.screen.view';

/// `event.name` of an action, instant or measured.
const eventAction = 'app.action';

/// `event.name` of the start of a flow run.
const eventFlowStart = 'app.flow.start';

/// `event.name` of the end of a flow run.
const eventFlowEnd = 'app.flow.end';

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
