// Core's behaviour, driven through its fakes: sending and retrying, the queue on disk, sessions, $first_open, the crash
// marker, errors, identify and reset, and what's dropped.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bellwether/src/core.dart';
import 'package:bellwether/src/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late Device device;
  setUp(() => device = Device());

  List<String> ids(int request) => [for (final e in device.sender.events(request)) e['id'] as String];

  group('sending', () {
    test('a retry sends the same ids', () async {
      final core = await device.launch();
      core.track('checkout_started', {});
      core.flush();
      await device.settle(core);
      device.sender.respond(503);
      await device.settle(core);

      device.advance(const Duration(seconds: 5)); // still inside the first 10-second backoff
      core.flush();
      await device.settle(core);
      expect(device.sender.bodies, hasLength(1));

      device.advance(const Duration(seconds: 10));
      core.flush();
      await device.settle(core);
      expect(device.sender.bodies, hasLength(2));
      expect(ids(0), hasLength(3)); // $session_start, $first_open, checkout_started
      expect(ids(1), ids(0));
    });

    test('a 400 drops the batch and carries on', () async {
      final core = await device.launch();
      core.flush();
      await device.settle(core);
      device.sender.respond(400);
      await device.settle(core);
      expect(core.queued, isEmpty);

      core.track('checkout_started', {});
      core.flush();
      await device.settle(core);
      expect(device.sender.bodies, hasLength(2));
    });

    test('a 401 drops the batch and stops sending', () async {
      final core = await device.launch();
      core.flush();
      await device.settle(core);
      device.sender.respond(401);
      await device.settle(core);
      expect(core.queued, isEmpty);

      device.advance(const Duration(minutes: 1));
      core.track('checkout_started', {});
      core.flush();
      await device.settle(core);
      expect(device.sender.bodies, hasLength(1));
      expect(core.queued.names, ['checkout_started']); // kept on disk for a launch with a good key
    });

    test('a 503 or no answer keeps the events', () async {
      final core = await device.launch();
      final before = core.queued.names;
      core.flush();
      await device.settle(core);
      device.sender.respond(503);
      await device.settle(core);
      expect(core.queued.names, before);

      device.advance(const Duration(minutes: 1));
      core.flush();
      await device.settle(core);
      device.sender.respond(null);
      await device.settle(core);
      expect(core.queued.names, before);
    });

    test('the backoff doubles to at most 10 minutes', () {
      expect([for (var f = 1; f <= 8; f++) Core.backoff(f).inSeconds], [10, 20, 40, 80, 160, 320, 600, 600]);
    });

    test('a 200 removes what was sent and keeps what came after', () async {
      final core = await device.launch();
      core.flush();
      await device.settle(core);
      core.track('checkout_started', {}); // made while the first request is out
      core.flush(); // one request at a time: this waits
      await device.settle(core);
      expect(device.sender.bodies, hasLength(1));
      device.sender.respond(200);
      await device.settle(core);
      expect(core.queued.names, ['checkout_started']);
    });

    test('twenty events send themselves', () async {
      final core = await device.launch(); // 2 events
      for (var i = 0; i < 17; i++) {
        core.track('step', {});
      }
      await device.settle(core);
      expect(device.sender.bodies, isEmpty);
      core.track('step', {});
      await device.settle(core);
      expect(device.sender.bodies, hasLength(1));
    });

    test('going to the background sends, and says when it is done', () async {
      final core = await device.launch();
      core.becameActive();
      var done = false;
      final background = core.enteredBackground().then((_) => done = true);
      await device.settle(core);
      expect(device.sender.bodies, hasLength(1));
      expect(done, isFalse);
      device.sender.respond(200);
      await background;
      expect(core.queued, isEmpty);
    });
  });

  group('the queue on disk', () {
    test('survives a restart', () async {
      final first = await device.launch();
      first.track('checkout_started', {'plan': 'pro'});
      await device.settle(first);
      final queued = [for (final e in first.queued) e.toJson()];
      expect(first.queued.names, [r'$session_start', r'$first_open', 'checkout_started']);

      final next = await device.launch();
      expect([for (final e in next.queued) e.toJson()], queued);
    });

    test('keeps the newest 1,000', () async {
      final core = await device.launch(); // 2 events; the first send at 20 never gets an answer
      for (var i = 0; i < 1005; i++) {
        core.track('step', {'i': i});
      }
      await device.settle(core);
      final queued = core.queued; // 1,007 made: the oldest 7 are gone
      expect(queued, hasLength(1000));
      expect(queued.first.props['i'], 5);
      expect(queued.last.props['i'], 1004);
      expect((await device.launch()).queued, hasLength(1000));
    });

    test('a queue that will not read is dropped, and the SDK carries on', () async {
      device.store.files[Core.queueFile] = '{"not": "a list"}';
      final core = await device.launch();
      expect(core.queued.names, [r'$session_start', r'$first_open']);
    });

    test('lives in a folder on a real disk too', () async {
      final folder = await Directory.systemTemp.createTemp('bellwether');
      addTearDown(() => folder.delete(recursive: true));
      final store = FileStore(Future.value(folder));
      await store.write('queue.json', '[1]');
      await store.write('queue.json', '[2]');
      expect(await store.read('queue.json'), '[2]');
      expect(folder.listSync().map((f) => f.uri.pathSegments.last), ['queue.json']); // no .tmp left behind
      await store.remove('queue.json');
      await store.remove('queue.json');
      expect(await store.read('queue.json'), isNull);
    });
  });

  group('sessions', () {
    test('a session ends after 30 idle minutes', () async {
      final core = await device.launch();
      core.becameActive();
      device.advance(const Duration(minutes: 30)); // exactly 30 minutes: the same session
      core.track('a', {});
      device.advance(const Duration(minutes: 30, seconds: 1));
      core.track('b', {});
      await device.settle(core);

      final events = core.queued;
      expect(events.names, [r'$session_start', r'$first_open', r'$app_open', 'a', r'$session_start', 'b']);
      expect(events.take(4).map((e) => e.sessionId).toSet(), hasLength(1));
      expect(events[4].sessionId, isNot(events[0].sessionId));
      expect(events[5].sessionId, events[4].sessionId);
    });

    test('coming back after 30 minutes away starts a new session', () async {
      final core = await device.launch();
      core.becameActive();
      device.advance(const Duration(hours: 1)); // an hour in the front, with nothing tracked
      await _background(device, core);
      device.advance(const Duration(minutes: 29));
      core.becameActive(); // 29 minutes away: the same session
      await _background(device, core);
      device.advance(const Duration(minutes: 31));
      core.becameActive();
      await device.settle(core);
      expect(core.queued.names, [
        r'$session_start', r'$first_open', r'$app_open', r'$app_open', r'$session_start', r'$app_open', //
      ]);
    });

    test('the session carries over a relaunch', () async {
      final first = await device.launch();
      first.becameActive();
      await _background(device, first);
      device.advance(const Duration(minutes: 5));
      final next = await device.launch();
      next.becameActive();
      await device.settle(next);
      expect(next.queued.names, [r'$session_start', r'$first_open', r'$app_open', r'$app_open']);
      expect(next.queued.map((e) => e.sessionId).toSet(), hasLength(1));
    });
  });

  test(r'$first_open is sent once for the device', () async {
    final first = await device.launch();
    first.reset();
    await device.settle(first);
    expect(first.queued.names, [r'$session_start', r'$first_open']);

    await device.launch();
    final third = await device.launch();
    expect(third.queued.names.where((n) => n == r'$first_open'), hasLength(1));
  });

  group('crashes', () {
    test('a session left open is sent as a crash at the next launch', () async {
      final first = await device.launch();
      first.becameActive();
      device.advance(const Duration(seconds: 5));
      first.track('checkout_started', {});
      await device.settle(first);
      final session = first.queued.last.sessionId;
      final lastAlive = device.now;
      expect(device.store.files.containsKey(Core.markerFile), isTrue);

      device.advance(const Duration(hours: 1)); // the app died in front; it's opened an hour later
      final next = await device.launch();
      final crash = next.queued.last;
      expect(crash.name, r'$crash');
      expect(crash.sessionId, session);
      expect(crash.time, '2026-11-10T09:00:05.000Z');
      expect(DateTime.parse(crash.time), lastAlive);
      expect(device.store.files.containsKey(Core.markerFile), isFalse);
      expect((await device.launch()).queued.names.where((n) => n == r'$crash'), hasLength(1));
    });

    test('no crash after the background or a quit', () async {
      final first = await device.launch();
      first.becameActive();
      await _background(device, first);
      expect(device.store.files.containsKey(Core.markerFile), isFalse);

      final second = await device.launch();
      second.becameActive();
      second.willTerminate();
      await device.settle(second);
      expect(device.store.files.containsKey(Core.markerFile), isFalse);

      final third = await device.launch(); // never came to the front: a background launch
      third.track('synced', {});
      await device.settle(third);
      expect(device.store.files.containsKey(Core.markerFile), isFalse);
      expect((await device.launch()).queued.names, isNot(contains(r'$crash')));
    });
  });

  group('errors', () {
    test(r'an uncaught error is $error with its message, at most ten a launch', () async {
      final core = await device.launch();
      core.error('Bad state: ${'x' * 300}');
      for (var i = 0; i < 20; i++) {
        core.error('again');
      }
      await device.settle(core);
      final errors = core.queued.where((e) => e.name == r'$error').toList();
      expect(errors, hasLength(10));
      expect(errors.first.props, {'message': 'Bad state: ${'x' * 189}'});
    });
  });

  group('identify and reset', () {
    test('identify ties the device to a person once', () async {
      final core = await device.launch();
      core.identify('u_123');
      core.track('a', {});
      core.identify('u_123'); // the same person again: nothing new
      core.identify('not valid'); // ignored
      await device.settle(core);

      final events = core.queued;
      expect(events.names, [r'$session_start', r'$first_open', r'$identify', 'a']);
      expect(events.map((e) => e.userId), [null, null, 'u_123', 'u_123']);

      final next = await device.launch();
      next.track('b', {});
      await device.settle(next);
      expect(next.queued.last.userId, 'u_123');
    });

    test('reset starts afresh for the next person', () async {
      final core = await device.launch();
      core.identify('u_123');
      core.reset();
      core.track('a', {});
      await device.settle(core);

      final events = core.queued;
      expect(events.names, [r'$session_start', r'$first_open', r'$identify', r'$session_start', 'a']);
      expect(events[4].userId, isNull);
      expect(events[4].anonId, isNot(events[2].anonId));
      expect(events[4].sessionId, isNot(events[2].sessionId));
    });
  });

  test('calls made before the stored state is read run after it, at their own time', () async {
    final core = Core(
      key: testKey,
      store: device.store,
      send: device.sender.send,
      fetch: device.fetcher.fetch,
      now: () => device.now,
    );
    core.track('early', {'plan': 'pro'});
    expect(core.variant('reply_nudge'), 'control');
    await core.open(testContext);
    expect(core.queued.names, [r'$session_start', r'$first_open', 'early']);
  });

  test('bad names and props are dropped', () async {
    final core = await device.launch();
    core.track('SignUp', {});
    core.track(r'$custom', {});
    core.track('signup_completed', {'plan': 'pro', 'Plan': 'pro', 'ratio': double.nan, 'when': DateTime(2026)});
    core.screen('');
    await device.settle(core);

    final events = core.queued;
    expect(events.names, [r'$session_start', r'$first_open', 'signup_completed']);
    expect(events.last.props, {'plan': 'pro'});
  });

  test('screens go on later events', () async {
    final core = await device.launch();
    core.screen('Home');
    core.track('a', {});
    await device.settle(core);
    expect(jsonDecode(jsonEncode(core.queued.last.toJson())), containsPair('context', containsPair('screen', 'Home')));
  });
}

// The app leaves the front. Its send is never answered, so what it sent stays queued for the test to see.
Future<void> _background(Device device, Core core) async {
  unawaited(core.enteredBackground());
  await device.settle(core);
}
