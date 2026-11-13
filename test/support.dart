// What the Core tests share: a clock the test sets, a sender and a settings fetcher that hold each request until the
// test answers it, draws the test scripts, and a store in memory. Launching a second Core on the same store is the
// app's next launch.

import 'dart:async';
import 'dart:convert';

import 'package:bellwether/src/core.dart';
import 'package:bellwether/src/event.dart';
import 'package:bellwether/src/store.dart';

const testKey = 'bw_pk_0123456789abcdefghijklmn';
const testContext = Context(appVersion: '2.3.0', build: '45', os: 'Android', device: 'phone', locale: 'en-GB');

DateTime at(String iso) => DateTime.parse(iso);

final class MemoryStore implements Store {
  final files = <String, String>{};

  @override
  Future<String?> read(String name) async => files[name];

  @override
  Future<void> write(String name, String text) async => files[name] = text;

  @override
  Future<void> remove(String name) async => files.remove(name);
}

final class FakeSender {
  final bodies = <String>[];
  final _waiting = <Completer<int?>>[];

  Future<int?> send(String body) {
    bodies.add(body);
    final answer = Completer<int?>();
    _waiting.add(answer);
    return answer.future;
  }

  // Answers the oldest request still waiting: an HTTP status, or null for no answer at all.
  void respond(int? status) => _waiting.removeAt(0).complete(status);

  // The events in one request, as JSON.
  List<Map<String, Object?>> events(int request) {
    final body = jsonDecode(bodies[request]) as Map<String, Object?>;
    return (body['events'] as List<Object?>).cast<Map<String, Object?>>();
  }
}

final class FakeFetcher {
  var count = 0;
  final _waiting = <Completer<Fetched>>[];

  Future<Fetched> fetch() {
    count++;
    final answer = Completer<Fetched>();
    _waiting.add(answer);
    return answer.future;
  }

  // Answers the oldest fetch still waiting: a status and a body, or nulls for no answer at all.
  void respond(int? status, [String? body]) => _waiting.removeAt(0).complete((status: status, body: body));
}

// One test's device: its clock, store, network and draws, kept across launches.
final class Device {
  var now = at('2026-11-10T09:00:00.000Z');
  final store = MemoryStore();
  final sender = FakeSender();
  final fetcher = FakeFetcher();
  final draws = <double>[]; // used in order; past the end, 0

  void set(String iso) => now = at(iso);
  void advance(Duration by) => now = now.add(by);

  // The app starting, at the clock's time, with what it kept read back.
  Future<Core> launch() async {
    final core = Core(
      key: testKey,
      store: store,
      send: sender.send,
      fetch: fetcher.fetch,
      now: () => now,
      random: () => draws.isEmpty ? 0 : draws.removeAt(0),
    );
    await core.open(testContext);
    await settle(core);
    return core;
  }

  // Lets answers given to the fakes reach Core, and its writes finish.
  Future<void> settle(Core core) async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await core.saved;
  }
}

extension Names on List<Event> {
  List<String> get names => [for (final e in this) e.name];
}
