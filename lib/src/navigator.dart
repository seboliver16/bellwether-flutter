// Names screens from the app's routes: `navigatorObservers: [BellwetherNavigatorObserver()]` sends $screen with a
// page route's name each time it's shown, whether pushed, replaced or returned to.

import 'package:flutter/widgets.dart';

import 'bellwether.dart';

/// Sends `$screen` with the route's name each time a named page route is shown. Dialogs, sheets and unnamed routes
/// aren't screens and send nothing.
class BellwetherNavigatorObserver extends NavigatorObserver {
  /// `screen` is where the names go: `Bellwether.screen` unless a test says otherwise.
  BellwetherNavigatorObserver({void Function(String name) screen = Bellwether.screen}) : _screen = screen;

  final void Function(String name) _screen;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _show(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _show(newRoute);

  // Back to the route underneath, which is on screen again.
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) _show(previousRoute);
  }

  void _show(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (route is PageRoute<dynamic> && name != null && name.isNotEmpty) _screen(name);
  }
}
