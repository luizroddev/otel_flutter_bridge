import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'pipeline.dart';
import 'semantics.dart';

/// Screen and flow values of one span.
typedef AppContextValues = ({String? screen, String? flow, String? flowId});

// What each started span was stamped with, so children (Dart, and native
// through the channel) can copy it. The SDK puts this same span object in
// the context of its children.
final _stamped = Expando<AppContextValues>();

// Zone key for values that came from native code with a remote parent.
const _remoteValuesKey = #otelFlutterBridgeRemoteAppContext;

/// The values [span] was stamped with, or null. Library use.
AppContextValues? appContextOf(Object? span) =>
    span == null ? null : _stamped[span];

/// Runs [fn] so spans started in it without a local parent take [values]
/// instead of the current [AppContext]. Library use.
R runWithRemoteAppContext<R>(AppContextValues values, R Function() fn) =>
    runZoned(fn, zoneValues: {_remoteValuesKey: values});

/// Where the user is in the app: the current screen, flow and user. Stamped
/// on every Dart span **when it starts**, as [appScreenKey], [appFlowKey],
/// [appFlowInstanceKey] and [userIdKey].
///
/// `Journey` keeps it up to date (`Journey.screen`, `Journey.startFlow`,
/// `Journey.setUser`); set it directly only when you do not use `Journey`.
/// Values must be fixed names such as `checkout.review`, never paths with
/// ids.
///
/// A span with a local parent copies the parent's screen and flow instead,
/// so every span of one trace carries the same screen and flow even if the
/// user navigates while it runs. The values also travel to native code with
/// `invokeTraced`, so native children carry them too.
abstract final class AppContext {
  /// The current screen, or null.
  static String? screen;

  /// The current flow (a journey across screens), or null.
  static String? flow;

  /// The current run of [flow], or null. Set by `Journey.startFlow`.
  static String? flowInstanceId;

  /// The current user id, or null. Set by `Journey.setUser`.
  static String? userId;

  /// The current values, as stamped on a span that starts now.
  static AppContextValues get values =>
      (screen: screen, flow: flow, flowId: flowInstanceId);

  /// Clears every value.
  static void clear() {
    screen = null;
    flow = null;
    flowInstanceId = null;
    userId = null;
  }
}

/// Stamps [AppContext] and, when [session] is given, `session.id` on spans
/// at start. Installed by `OtelFlutterBridge.initialize`.
class AppContextSpanProcessor implements SpanProcessor {
  /// Creates the processor. [session] is read when each span starts, so a
  /// session renewed later never takes older spans.
  AppContextSpanProcessor({this.session});

  /// Where `session.id` comes from.
  final SessionIdProvider? session;

  @override
  Future<void> onStart(Span span, Context? parentContext) async {
    try {
      final parent = parentContext?.span;
      final values = (parent == null ? null : _stamped[parent]) ??
          Zone.current[_remoteValuesKey] as AppContextValues? ??
          AppContext.values;
      _stamped[span] = values;
      final screen = values.screen;
      final flow = values.flow;
      final flowId = values.flowId;
      final user = AppContext.userId;
      if (screen != null) span.setStringAttribute(appScreenKey, screen);
      if (flow != null) span.setStringAttribute(appFlowKey, flow);
      if (flowId != null) span.setStringAttribute(appFlowInstanceKey, flowId);
      if (user != null) span.setStringAttribute(userIdKey, user);
      final s = session;
      if (s != null) span.setStringAttribute(sessionIdKey, s.currentId);
    } catch (_) {
      // Telemetry never breaks the app.
    }
  }

  @override
  Future<void> onEnd(Span span) async {}

  @override
  Future<void> onNameUpdate(Span span, String newName) async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<void> forceFlush() async {}
}
