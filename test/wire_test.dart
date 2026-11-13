// What goes over the wire: the batch's exact JSON against a fixture that parseBatch accepts, event ids, times, and a
// batch's limits.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bellwether/src/event.dart';
import 'package:bellwether/src/ids.dart';
import 'package:bellwether/src/rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final _v7 = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

int millisOf(String id) => int.parse(id.replaceAll('-', '').substring(0, 12), radix: 16);

Event _event(int i, Map<String, Object> props) => Event(
      id: 'id$i',
      name: 'step',
      time: '2026-11-10T09:00:00.000Z',
      anonId: 'a',
      userId: null,
      sessionId: 's',
      props: props,
      context: testContext,
    );

void main() {
  // test/fixtures/batch.json was written by hand to parseBatch's rules (packages/analytics/src/event.ts), and
  // packages/analytics/test/event.test.ts runs it through parseBatch: all six events accepted, nothing removed.
  test('the batch matches the fixture', () async {
    final device = Device();
    final core = await device.launch(); // a first launch: $session_start, $first_open
    device.set('2026-11-10T09:00:00.250Z');
    core.becameActive();
    device.set('2026-11-10T09:00:01.002Z');
    core.identify('u_123');
    device.set('2026-11-10T09:00:01.500Z');
    core.screen('SignUp');
    device.set('2026-11-10T09:00:03.120Z');
    core.track('signup_completed', {'plan': 'pro', 'seats': 3, 'trial': true});
    device.set('2026-11-10T09:00:04.000Z');
    core.flush();
    await device.settle(core);

    final sent = jsonDecode(device.sender.bodies.single) as Map<String, Object?>;
    final fixture = jsonDecode(File('test/fixtures/batch.json').readAsStringSync()) as Map<String, Object?>;
    final events = device.sender.events(0);
    final expected = (fixture['events'] as List<Object?>).cast<Map<String, Object?>>();
    expect(events, hasLength(expected.length));

    // The ids are random. Check their form here, then take the fixture's, so everything else compares exactly.
    final anonId = events[0]['anon_id'] as String;
    final sessionId = events[0]['session_id'] as String;
    expect(isId(anonId), isTrue);
    expect(isId(sessionId), isTrue);
    var previous = '';
    for (var i = 0; i < events.length; i++) {
      final id = events[i]['id'] as String;
      expect(id, matches(_v7));
      expect(millisOf(id), DateTime.parse(events[i]['time'] as String).millisecondsSinceEpoch);
      expect(id.compareTo(previous), greaterThan(0));
      previous = id;
      expect(events[i]['anon_id'], anonId);
      expect(events[i]['session_id'], sessionId);
      for (final field in ['id', 'anon_id', 'session_id']) {
        events[i][field] = expected[i][field];
      }
    }
    sent['events'] = events;
    expect(sent, fixture);
  });

  test('ids are lowercase UUIDv7 with their time', () {
    final id = UuidV7().next(at('2026-11-10T09:00:01.002Z'));
    expect(id, matches(_v7));
    expect(millisOf(id), 1794301201002);
  });

  test('ids sort in the order they were made', () {
    final ids = UuidV7();
    final now = at('2026-11-10T09:00:00.000Z');
    // 5,000 in one millisecond runs past the 12-bit counter; then the clock steps back a second.
    final made = [
      for (var i = 0; i < 5000; i++) ids.next(now),
      for (var i = 0; i < 10; i++) ids.next(now.subtract(const Duration(seconds: 1))),
      for (var i = 1; i <= 10; i++) ids.next(now.add(Duration(seconds: i))),
    ];
    expect(made, [...made]..sort());
    expect(made.toSet(), hasLength(made.length));
    expect(made.every(_v7.hasMatch), isTrue);
  });

  test('device and session ids are UUIDv4', () {
    expect(
        uuidV4(Random(1)), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });

  test('times are UTC with milliseconds', () {
    expect(Event.timeOf(at('2026-11-10T09:00:01.002Z')), '2026-11-10T09:00:01.002Z');
    expect(Event.timeOf(at('2026-12-31T23:59:59.999Z')), '2026-12-31T23:59:59.999Z');
    expect(Event.timeOf(at('2026-11-10T09:00:01.002345Z')), '2026-11-10T09:00:01.002Z');
    expect(Event.timeOf(DateTime.fromMillisecondsSinceEpoch(0)), '1970-01-01T00:00:00.000Z');
  });

  test('a batch holds at most 500 events', () {
    final batch = batchBody(testKey, [for (var i = 0; i < 600; i++) _event(i, const {})], DateTime.now());
    expect(batch.count, 500);
    expect((jsonDecode(batch.body) as Map<String, Object?>)['events'], hasLength(500));
  });

  test('a batch stays under 512 KB', () {
    final big = {for (var i = 0; i < 30; i++) 'p$i': 'x' * 1000};
    final events = [for (var i = 0; i < 100; i++) _event(i, big)]; // about 30 KB each: 100, 50 and 25 are too many
    final batch = batchBody(testKey, events, DateTime.now());
    expect(utf8.encode(batch.body).length, lessThanOrEqualTo(512000));
    expect(batch.count, 12);
  });

  test('queued events read back as they were written', () {
    final event = Event(
      id: 'x',
      name: 'step',
      time: '2026-11-10T09:00:00.000Z',
      anonId: 'a',
      userId: 'u',
      sessionId: 's',
      props: const {'plan': 'pro', 'seats': 3, 'price': 9.5, 'trial': true, 'paid': false, 'one': '1'},
      context: testContext.withScreen('Home'),
      sample: 0.25,
    );
    final back = Event.fromJson(jsonDecode(jsonEncode(event.toJson())));
    expect(back.toJson(), event.toJson());
  });

  test('context leaves out what Ingest would refuse, and reads the OS version only where it is one', () {
    expect(const Context(os: 'Android', build: '', locale: 'en-GB').toJson(), {'os': 'Android', 'locale': 'en-GB'});
    expect(Context(appVersion: 'v' * 201).toJson(), isEmpty);
    expect(Context.osVersionOf('iOS', 'Version 18.1 (Build 22B83)'), '18.1');
    expect(Context.osVersionOf('Android', 'Linux 5.10.43-android12-9 #1 SMP PREEMPT'), isNull);
  });
}
