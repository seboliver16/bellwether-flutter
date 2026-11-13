// Tells Core what the app is doing: coming to the front, going to the background, quitting, and errors nobody caught.
// It also sends every 10 seconds while the app is in front. Only Flutter's part lives here; what each moment means is
// in Core, and tested there.

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'core.dart';

final class Hooks with WidgetsBindingObserver {
  Hooks(this._core);

  final Core _core;
  Timer? _timer;
  FlutterExceptionHandler? _flutterErrors;
  ErrorCallback? _platformErrors;

  // Errors go on to whatever handled them before, so Crashlytics, Sentry and the console still see every one.
  void install() {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _flutterErrors = FlutterError.onError;
    FlutterError.onError = (details) {
      _core.error(details.exceptionAsString());
      _flutterErrors?.call(details);
    };
    // The engine's own dispatcher: flutter_test's stand-in for it doesn't take an onError.
    _platformErrors = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _core.error(error.toString());
      return _platformErrors?.call(error, stack) ?? false;
    };
    // Started after the app came to the front: that change has already gone by.
    if (binding.lifecycleState == AppLifecycleState.resumed) _resumed();
  }

  // Undoes install, for tests, which must leave Flutter's handlers as they found them.
  @visibleForTesting
  void remove() {
    final binding = WidgetsBinding.instance;
    binding.removeObserver(this);
    FlutterError.onError = _flutterErrors;
    PlatformDispatcher.instance.onError = _platformErrors;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _resumed();
      case AppLifecycleState.paused:
        _timer?.cancel();
        _timer = null;
        unawaited(_core.enteredBackground());
      case AppLifecycleState.detached:
        _core.willTerminate();
      case AppLifecycleState.inactive || AppLifecycleState.hidden:
        break; // passing states on the way to or from the front: paused and resumed say what happened
    }
  }

  void _resumed() {
    _core.becameActive();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _core.flush());
  }
}
