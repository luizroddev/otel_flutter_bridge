import 'package:flutter/widgets.dart';

import 'journey.dart';

/// Records a screen view (`Journey.screen`) when a route becomes visible:
/// pushed, replaced, or revealed by a pop.
///
/// ```dart
/// MaterialApp(navigatorObservers: [JourneyNavigatorObserver()]);
/// ```
///
/// By default only page routes count (dialogs and bottom sheets do not),
/// and a route maps to its `RouteSettings.name`. Pass [screenOf] to map
/// routes to your [JourneyScreen] enum; return null to fall back to the
/// route name, or set [useRouteNames] to false to skip unmapped routes.
/// Route names must be fixed (`/cart`), never paths with ids.
class JourneyNavigatorObserver extends NavigatorObserver {
  /// Creates the observer.
  JourneyNavigatorObserver({
    this.screenOf,
    this.useRouteNames = true,
    bool Function(Route<dynamic> route)? isScreen,
  }) : _isScreen = isScreen ?? ((route) => route is PageRoute);

  /// Maps a route to a screen, or null.
  final JourneyScreen? Function(Route<dynamic> route)? screenOf;

  /// Whether unmapped routes use their name.
  final bool useRouteNames;

  final bool Function(Route<dynamic> route) _isScreen;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _show(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _show(newRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isScreen(route)) _show(previousRoute);
  }

  void _show(Route<dynamic>? route) {
    if (route == null) return;
    try {
      if (!_isScreen(route)) return;
      final screen = screenOf?.call(route);
      if (screen != null) {
        Journey.screen(screen);
        return;
      }
      final name = route.settings.name;
      if (useRouteNames && name != null && name.isNotEmpty) {
        Journey.screenNamed(name);
      }
    } catch (_) {
      // Telemetry never breaks the app.
    }
  }
}
