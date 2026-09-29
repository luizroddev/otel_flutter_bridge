/// Attribute keys and names shared by the Dart and native sides.
/// See `docs/specs/naming.md`.
library;

/// `session.id`, from the OpenTelemetry session semantic conventions.
const sessionIdKey = 'session.id';

/// The screen the user was on when a span started. See `AppContext`.
const appScreenKey = 'app.screen';

/// The flow (journey across screens) the user was in when a span started.
/// See `AppContext`.
const appFlowKey = 'app.flow';

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
