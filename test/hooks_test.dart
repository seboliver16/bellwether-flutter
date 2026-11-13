// Flutter's part: the lifecycle and error hooks feed Core, and the navigator observer names screens from routes.

import 'dart:async';

import 'package:bellwether/bellwether.dart';
import 'package:bellwether/src/hooks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('hooks', () {
    late Device device;
    late Hooks hooks;
    final seen = <FlutterErrorDetails>[];
    late FlutterExceptionHandler? before;

    setUp(() async {
      device = Device();
      before = FlutterError.onError;
      FlutterError.onError = seen.add; // what handled errors before Bellwether, which must still see them
    });

    tearDown(() {
      hooks.remove();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); // paused, Flutter draws no frames
      FlutterError.onError = before;
      seen.clear();
    });

    test(r'the front and the background are $app_open and a send', () async {
      final core = await device.launch();
      hooks = Hooks(core)..install();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await device.settle(core);
      expect(core.queued.names, contains(r'$app_open'));
      expect(device.store.files.containsKey('session.json'), isTrue);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await device.settle(core);
      expect(device.sender.bodies, hasLength(1));
      expect(device.store.files.containsKey('session.json'), isFalse);
    });

    test(r'errors nobody caught are $error, and still reach what handled them before', () async {
      final core = await device.launch();
      hooks = Hooks(core)..install();
      FlutterError.reportError(FlutterErrorDetails(exception: StateError('the cart is empty')));
      final handled = PlatformDispatcher.instance.onError!(ArgumentError('no price'), StackTrace.empty);
      await device.settle(core);

      expect(seen, hasLength(1));
      expect(handled, isFalse); // nothing handled it before, so the engine still reports it
      expect(core.queued.where((e) => e.name == r'$error').map((e) => e.props['message']), [
        'Bad state: the cart is empty',
        'Invalid argument(s): no price',
      ]);
    });
  });

  group('the navigator observer', () {
    testWidgets('names screens from page routes as they are shown', (tester) async {
      final screens = <String>[];
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [BellwetherNavigatorObserver(screen: screens.add)],
        routes: {
          '/': (_) => const Text('home'),
          'SignUp': (_) => const Text('sign up'),
          'Plans': (_) => const Text('plans'),
        },
      ));
      unawaited(navigator.currentState!.pushNamed('SignUp'));
      await tester.pumpAndSettle();
      unawaited(navigator.currentState!.pushReplacementNamed('Plans'));
      await tester.pumpAndSettle();
      unawaited(showDialog<void>(context: navigator.currentContext!, builder: (_) => const Text('sure?')));
      await tester.pumpAndSettle();
      navigator.currentState!.pop(); // the dialog: the page under it never left
      await tester.pumpAndSettle();
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('unnamed'))));
      await tester.pumpAndSettle();
      navigator.currentState!.pop(); // back to Plans
      await tester.pumpAndSettle();

      expect(screens, ['/', 'SignUp', 'Plans', 'Plans']);
    });
  });
}
