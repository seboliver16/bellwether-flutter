// The settings file (docs/telemetry.md §4): what Bellwether wants this app to record right now. Ingest serves it at
// GET {endpoint}/v1/settings?key=…; Core fetches it at start and again every `ttl` seconds, keeps the last good copy,
// and uses the defaults until it has one. `parseSettings` is a copy of packages/analytics/src/settings.ts, held to it by
// sdks/conformance/switches.json, and the one place the file becomes typed.

import 'dart:convert';

final class Settings {
  const Settings({
    this.version = 0,
    this.ttl = 600,
    this.capture = const Capture(),
    this.sample = const {},
    this.probes = const {},
    this.switches = const {},
  });

  final int version; // bumped on every change
  final int ttl; // seconds until the next fetch
  final Capture capture;
  final Map<String, double> sample; // event name -> the share kept, 0 to 1; missing means 1
  final Map<String, Probe> probes; // the probes switched on; missing means off
  final Map<String, Switch> switches; // places with variants (loops design §7.1); missing means the first variant

  static const defaults = Settings();

  // The file as Ingest sent it, or null when it isn't a JSON object: then it's ignored whole, and the last good one
  // stays in force. Inside an object, parsing is lenient, as parseSettings is.
  static Settings? parse(String body) {
    final Object? raw;
    try {
      raw = jsonDecode(body);
    } on FormatException {
      return null; // not JSON: the caller warns and keeps what's in force
    }
    return raw is Map<String, Object?> ? parseSettings(raw) : null;
  }

  // The share of `name` events kept.
  double rate(String name) => sample[name] ?? 1;

  // What a probe call sends: null while the probe is off; else its props (only the listed ones, when it lists them)
  // and the share of calls it's sent at.
  ({Map<String, Object> props, double rate})? probe(String name, Map<String, Object> props) {
    final probe = probes[name];
    if (probe == null) return null;
    final listed = probe.props;
    if (listed == null) return (props: props, rate: probe.sample);
    return (
      props: {
        for (final e in props.entries)
          if (listed.contains(e.key)) e.key: e.value
      },
      rate: probe.sample
    );
  }

  // Whether an event kept at `rate` is sent, given a draw in [0, 1). A rate of 1 keeps it without drawing.
  static bool keeps(double rate, double Function() draw) => rate >= 1 || draw() < rate;
}

// Which automatic detail events to record. Flutter records none of these yet; they're read so the shape matches.
final class Capture {
  const Capture({this.clicks = true, this.submits = true, this.requests = true, this.taps = true});

  final bool clicks;
  final bool submits;
  final bool requests;
  final bool taps;
}

final class Probe {
  const Probe(this.sample, [this.props]);

  final double sample; // the share of calls sent, 0 to 1
  final List<String>? props; // the only props it sends; null sends them all
}

enum SwitchUnit { device, person }

// A switch: its variants, the first being what people had before, the share each gets, the salt that keeps one
// switch's split apart from another's, whether it's on, and who stays on one side: the device, or the signed-in person
// once known.
final class Switch {
  const Switch({required this.variants, required this.split, required this.salt, required this.on, required this.unit});

  final List<String> variants;
  final List<double> split;
  final String salt;
  final bool on;
  final SwitchUnit unit;

  // The variant an id gets: the first whose share, added to those before it, passes the id's bucket. Off, the first.
  String variantOf(String id) {
    if (!on) return variants.first;
    final total = split.fold<double>(0, (a, b) => a + b);
    final at = bucketOf(salt, id) * total;
    var sum = 0.0;
    for (var i = 0; i < variants.length; i++) {
      sum += split[i];
      if (at < sum) return variants[i];
    }
    return variants.last;
  }
}

// ---------- parsing ----------

const _ttlMin = 60;
const _ttlMax = 86400;
final _eventName = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final _propName = RegExp(r'^[a-z][a-z0-9_]{0,39}$');
final _sampled = RegExp(r'^\$?[a-z][a-z0-9_]{0,63}$');
final _variant = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

bool _isRate(Object? value) => value is num && value >= 0 && value <= 1;

Iterable<MapEntry<String, Object?>> _entries(Object? value) =>
    value is Map<String, Object?> ? value.entries : const <MapEntry<String, Object?>>[];

// Lenient: a part that's missing or malformed falls back to its default, so a bad write never stops the app. A probe
// whose props list is malformed stays off rather than sending every prop.
Settings parseSettings(Map<String, Object?> s) {
  final capture = switch (s['capture']) { Map<String, Object?> m => m, _ => const <String, Object?>{} };
  final sample = <String, double>{
    for (final MapEntry(:key, :value) in _entries(s['sample']))
      if (_sampled.hasMatch(key) && value is num && _isRate(value)) key: value.toDouble(),
  };
  final probes = <String, Probe>{};
  for (final MapEntry(:key, :value) in _entries(s['probes'])) {
    if (!_eventName.hasMatch(key) || value is! Map<String, Object?>) continue;
    final share = value['sample'];
    if (share is! num || !_isRate(share)) continue;
    final props = value['props'];
    if (!value.containsKey('props')) {
      probes[key] = Probe(share.toDouble());
    } else if (props is List<Object?>) {
      probes[key] = Probe(share.toDouble(), [
        for (final p in props)
          if (p is String && _propName.hasMatch(p)) p
      ]);
    }
  }
  final switches = <String, Switch>{};
  for (final MapEntry(:key, :value) in _entries(s['switches'])) {
    final sw = _parseSwitch(value);
    if (_eventName.hasMatch(key) && sw != null) switches[key] = sw;
  }
  final version = s['version'];
  final ttl = s['ttl'];
  return Settings(
    version: version is num && version == version.truncate() && version >= 0 ? version.toInt() : 0,
    ttl: ttl is num && ttl >= _ttlMin && ttl <= _ttlMax ? ttl.round() : Settings.defaults.ttl,
    capture: Capture(
      clicks: capture['clicks'] != false,
      submits: capture['submits'] != false,
      requests: capture['requests'] != false,
      taps: capture['taps'] != false,
    ),
    sample: sample,
    probes: probes,
    switches: switches,
  );
}

// A switch that's malformed in any part is dropped, so its code keeps the first variant: what people had before.
Switch? _parseSwitch(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final (variants, split, salt) = (raw['variants'], raw['split'], raw['salt']);
  if (variants is! List<Object?> || split is! List<Object?> || salt is! String) return null;
  if (variants.length < 2 || variants.length > 8 || split.length != variants.length) return null;
  final names = [
    for (final v in variants)
      if (v is String && _variant.hasMatch(v)) v
  ];
  if (names.length != variants.length || names.toSet().length != names.length) return null;
  final shares = [
    for (final n in split)
      if (n is num && n.isFinite && n >= 0) n.toDouble()
  ];
  if (shares.length != split.length || shares.fold<double>(0, (a, b) => a + b) <= 0) return null;
  if (salt.isEmpty || salt.length > 64) return null;
  return Switch(
    variants: names,
    split: shares,
    salt: salt,
    on: raw['on'] == true,
    unit: raw['unit'] == 'person' ? SwitchUnit.person : SwitchUnit.device,
  );
}

// ---------- which side someone is on ----------

// Where an id falls in [0, 1) for a salt: FNV-1a over the UTF-8 bytes of "salt.id", then murmur3's finalizer, over
// 2^32. The same as every other SDK (sdks/conformance/switches.json).
double bucketOf(String salt, String id) {
  var h = 0x811c9dc5;
  for (final byte in utf8.encode('$salt.$id')) {
    h ^= byte;
    h = _mul32(h, 0x01000193);
  }
  h ^= h >> 16;
  h = _mul32(h, 0x85ebca6b);
  h ^= h >> 13;
  h = _mul32(h, 0xc2b2ae35);
  h ^= h >> 16;
  return h / 4294967296;
}

// a * b mod 2^32, for a and b under 2^32, as JavaScript's Math.imul does. Split into 16-bit halves so no product
// passes 2^53 and nothing depends on how a platform's integers overflow.
int _mul32(int a, int b) {
  final (aHi, aLo) = ((a >> 16) & 0xffff, a & 0xffff);
  final (bHi, bLo) = ((b >> 16) & 0xffff, b & 0xffff);
  return (aLo * bLo + (((aHi * bLo + aLo * bHi) & 0xffff) << 16)) & 0xffffffff;
}
