// The settings file: parsing, the defaults and the last good copy, fetching again after ttl, sampling, probes, and
// switches, held to the cases every SDK shares (sdks/conformance/switches.json).

import 'dart:convert';
import 'dart:io';

import 'package:bellwether/src/core.dart';
import 'package:bellwether/src/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const fullSettings = '''
{
  "version": 7, "ttl": 300,
  "capture": { "clicks": true, "submits": false, "requests": false, "taps": true },
  "sample": { "\$tap": 0.25, "step": 0 },
  "probes": { "cart_viewed": { "sample": 1, "props": ["items"] }, "search_ran": { "sample": 0.5 } },
  "switches": {
    "reply_nudge": { "variants": ["control", "on"], "split": [0.5, 0.5], "salt": "reply_nudge.1", "on": true },
    "by_person": { "variants": ["control", "on"], "split": [1, 1], "salt": "p", "on": true, "unit": "person" },
    "dark": { "variants": ["control", "on"], "split": [1, 1], "salt": "d" }
  }
}
''';

Map<String, Object?> _switchJson(Switch sw) =>
    {'variants': sw.variants, 'split': sw.split, 'salt': sw.salt, 'on': sw.on, 'unit': sw.unit.name};

void main() {
  group('parsing', () {
    test('a full file parses', () {
      final s = Settings.parse(fullSettings)!;
      expect((s.version, s.ttl), (7, 300));
      expect((s.capture.clicks, s.capture.submits, s.capture.requests, s.capture.taps), (true, false, false, true));
      expect(s.sample, {r'$tap': 0.25, 'step': 0});
      expect(s.probes.keys, ['cart_viewed', 'search_ran']);
      expect(s.probes['cart_viewed']!.sample, 1);
      expect(s.probes['cart_viewed']!.props, ['items']);
      expect(s.probes['search_ran']!.sample, 0.5);
      expect(s.probes['search_ran']!.props, isNull);
      expect(s.switches.keys, ['reply_nudge', 'by_person', 'dark']);
      expect(s.switches['dark']!.on, isFalse);
    });

    // As parseSettings in packages/analytics: lenient inside an object, so one bad part falls back on its own.
    test('a malformed part falls back to its default', () {
      final cases = <String, (String, bool Function(Settings))>{
        'no ttl': ('{}', (s) => s.ttl == 600),
        'a ttl under 60': ('{"ttl": 5}', (s) => s.ttl == 600),
        'a ttl over a day': ('{"ttl": 86401}', (s) => s.ttl == 600),
        'a ttl that rounds': ('{"ttl": 90.6}', (s) => s.ttl == 91),
        'a version that is not whole': ('{"version": 1.5}', (s) => s.version == 0),
        'missing capture flags': ('{"capture": {"taps": false}}', (s) => s.capture.requests && !s.capture.taps),
        'a flag that is 0': ('{"capture": {"taps": 0}}', (s) => s.capture.taps),
        'a share over 1': ('{"sample": {"a": 1.5, "b": 0.5}}', (s) => s.sample.keys.join() == 'b'),
        'a share that is true': ('{"sample": {"a": true}}', (s) => s.sample.isEmpty),
        'a bad event name': ('{"sample": {"Bad": 0.5}}', (s) => s.sample.isEmpty),
        'a probe without a share': ('{"probes": {"a": {}}}', (s) => s.probes.isEmpty),
        r'a probe with a $ name': (r'{"probes": {"$tap": {"sample": 1}}}', (s) => s.probes.isEmpty),
        'a probe whose props are not a list': (
          '{"probes": {"a": {"sample": 1, "props": "x"}}}',
          (s) => s.probes.isEmpty
        ),
        'a probe with a bad prop': (
          '{"probes": {"a": {"sample": 1, "props": ["ok", "Bad", 3]}}}',
          (s) => s.probes['a']!.props!.join() == 'ok',
        ),
      };
      for (final MapEntry(key: what, value: (body, holds)) in cases.entries) {
        expect(holds(Settings.parse(body)!), isTrue, reason: what);
      }
    });

    test('what is not a settings file at all', () {
      for (final body in ['nope', '[]', '3', '{"ttl":']) {
        expect(Settings.parse(body), isNull, reason: body);
      }
    });
  });

  group('the cases every SDK shares', () {
    final cases = jsonDecode(File('../conformance/switches.json').readAsStringSync()) as Map<String, Object?>;
    List<Map<String, Object?>> list(String name) => (cases[name] as List<Object?>).cast<Map<String, Object?>>();

    test('puts each id in its exact bucket', () {
      for (final c in list('buckets')) {
        expect(bucketOf(c['salt'] as String, c['id'] as String), c['bucket'], reason: '${c['salt']} ${c['id']}');
      }
    });

    test('gives each id its variant', () {
      for (final c in list('variants')) {
        final sw = parseSettings({
          'switches': {'s': c['switch']}
        }).switches['s']!;
        expect(sw.variantOf(c['id'] as String), c['variant'], reason: '${c['switch']} ${c['id']}');
      }
    });

    test('reads each switch, dropping a malformed one whole', () {
      for (final c in list('settings')) {
        final raw = c['raw'] as Map<String, Object?>;
        final read = {
          for (final MapEntry(:key, :value) in parseSettings(raw).switches.entries) key: _switchJson(value)
        };
        expect(read, c['switches'], reason: jsonEncode(raw));
      }
    });
  });

  group('fetching, the last good copy and the defaults', () {
    test('the defaults apply until a file arrives, and it is kept', () async {
      final device = Device();
      final core = await device.launch();
      expect(device.fetcher.count, 1); // fetched at start
      expect(core.current, same(Settings.defaults));

      device.fetcher.respond(200, fullSettings);
      await device.settle(core);
      expect(core.current.capture.requests, isFalse);

      final next = await device.launch(); // the next launch uses the kept copy before its fetch answers
      expect(device.fetcher.count, 2);
      expect(next.current.ttl, 300);
      expect(next.current.switches.keys, core.current.switches.keys);
    });

    test('a failed or bad fetch keeps the last good file', () async {
      final device = Device();
      final core = await device.launch();
      device.fetcher.respond(200, fullSettings);
      await device.settle(core);
      final good = core.current;

      for (final (status, body) in [(null, null), (503, '{}'), (200, '{"ttl":')]) {
        device.advance(Duration(seconds: good.ttl));
        core.flush();
        await device.settle(core);
        device.fetcher.respond(status, body);
        await device.settle(core);
        expect(core.current, same(good));
      }
      expect((await device.launch()).current.ttl, 300);
    });

    test('fetched again once ttl has passed, one at a time', () async {
      final device = Device();
      final core = await device.launch();
      device.fetcher.respond(200, fullSettings); // ttl 300
      await device.settle(core);

      device.advance(const Duration(seconds: 299));
      core.flush();
      core.becameActive();
      await device.settle(core);
      expect(device.fetcher.count, 1);

      device.advance(const Duration(seconds: 1));
      core.flush();
      core.flush();
      await device.settle(core);
      expect(device.fetcher.count, 2);
    });
  });

  group('sampling and probes', () {
    test('sampled events carry their share', () async {
      final device = Device();
      final core = await device.launch();
      device.fetcher.respond(200, '{"sample": {"step": 0.25, "never": 0}}');
      await device.settle(core);

      device.draws.addAll([0.1, 0.3, 0.24]); // kept, dropped, kept
      for (var i = 0; i < 3; i++) {
        core.track('step', {});
      }
      core.track('never', {});
      core.track('other', {});
      await device.settle(core);

      final tail = core.queued.skip(core.queued.length - 3).toList();
      expect(tail.names, ['step', 'step', 'other']);
      expect(tail.map((e) => e.sample), [0.25, 0.25, null]);
      expect(tail.first.toJson()['sample'], 0.25);
      expect(tail.last.toJson().containsKey('sample'), isFalse);
    });

    test('a probe is sent only while it is on, at its share, with only its props', () async {
      final device = Device();
      final core = await device.launch();
      core.probe('cart_viewed', {'items': 3});
      await device.settle(core);
      expect(core.queued.names, isNot(contains('cart_viewed'))); // off until the file says otherwise

      device.fetcher.respond(200, fullSettings);
      await device.settle(core);
      core.probe('cart_viewed', {'items': 3, 'total': 20});
      device.draws.addAll([0.7, 0.2]); // search_ran at 0.5: dropped, kept
      core.probe('search_ran', {'q_len': 4});
      core.probe('search_ran', {'q_len': 5});
      core.probe('unknown_probe', {});
      core.probe(r'$tap', {});
      await device.settle(core);

      final probes = core.queued.where((e) => e.name != r'$session_start' && e.name != r'$first_open').toList();
      expect(probes.names, ['cart_viewed', 'search_ran']);
      expect(probes[0].props, {'items': 3});
      expect(probes[0].sample, isNull);
      expect(probes[1].props, {'q_len': 5});
      expect(probes[1].sample, 0.5);
    });
  });

  group('switches', () {
    Future<(Device, Core)> withSwitches() async {
      final device = Device();
      final core = await device.launch();
      device.fetcher.respond(200, fullSettings);
      await device.settle(core);
      return (device, core);
    }

    test(r'a switch that is on gives this device its side, and sends $exposure once a launch', () async {
      final device = Device();
      var core = await device.launch();
      expect(core.variant('reply_nudge'), 'control'); // not fetched yet: what people had before, and no exposure
      device.fetcher.respond(200, fullSettings);
      await device.settle(core);

      final anonId = core.queued.first.anonId;
      final side = core.current.switches['reply_nudge']!.variantOf(anonId);
      expect(core.variant('reply_nudge'), side);
      expect(core.variant('reply_nudge'), side);
      await device.settle(core);
      final exposures = core.queued.where((e) => e.name == r'$exposure').toList();
      expect(exposures.map((e) => e.props), [
        {'switch': 'reply_nudge', 'variant': side},
      ]);

      core = await device.launch(); // a new launch: the same side, and one more exposure
      expect(core.variant('reply_nudge'), side);
      await device.settle(core);
      expect(core.queued.where((e) => e.name == r'$exposure'), hasLength(2));
    });

    test('a switch that is off or unknown gives the first variant and sends nothing', () async {
      final (_, core) = await withSwitches();
      expect(core.variant('dark'), 'control');
      expect(core.variant('nowhere'), 'control');
      expect(core.queued.names, isNot(contains(r'$exposure')));
    });

    test('a person switch follows the signed-in person, and the device until then', () async {
      final (device, core) = await withSwitches();
      final sw = core.current.switches['by_person']!;
      final anonId = core.queued.first.anonId;
      // ids whose sides differ, so the test shows which one decided
      final person = ['u_1', 'u_2', 'u_3', 'u_4'].firstWhere((id) => sw.variantOf(id) != sw.variantOf(anonId));
      expect(core.variant('by_person'), sw.variantOf(anonId));

      final next = await device.launch();
      next.identify(person);
      expect(next.variant('by_person'), sw.variantOf(person));
    });
  });
}
