import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'semantics.dart';

/// Where the user is in the app: the current screen and flow. Stamped on
/// every Dart span **when it starts**, as [appScreenKey] and [appFlowKey].
///
/// Update it from navigation (for example a `NavigatorObserver` or the
/// router's listener) and at the start and end of a flow. Values must be
/// fixed names such as `checkout.review`, never paths with ids.
///
/// A span with a local parent copies the parent's values instead, so every
/// span of one trace carries the same screen and flow even if the user
/// navigates while it runs. Native spans are not stamped; they are found
/// through their Dart parent.
abstract final class AppContext {
  /// The current screen, or null.
  static String? screen;

  /// The current flow (a journey across screens), or null.
  static String? flow;

  /// Clears both values.
  static void clear() {
    screen = null;
    flow = null;
  }
}

/// Stamps [AppContext] on spans at start. Installed by
/// `OtelFlutterBridge.initialize`.
class AppContextSpanProcessor implements SpanProcessor {
  // What each started span was stamped with, so children can copy it.
  // The SDK puts this same span object in the context of its children.
  final _stamped = Expando<({String? screen, String? flow})>();

  @override
  Future<void> onStart(Span span, Context? parentContext) async {
    try {
      final parent = parentContext?.span;
      final values = (parent == null ? null : _stamped[parent]) ??
          (screen: AppContext.screen, flow: AppContext.flow);
      _stamped[span] = values;
      final screen = values.screen;
      final flow = values.flow;
      if (screen != null) span.setStringAttribute(appScreenKey, screen);
      if (flow != null) span.setStringAttribute(appFlowKey, flow);
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
