// The SDK's engine: identity, sessions, the crash marker, the queue on disk, sending, the settings file, sampling,
// probes and switches. It's plain Dart: it takes its clock, randomness, store, sender and fetcher as arguments, so tests
// drive it without Flutter or a network. The facade and the Flutter hooks are thin layers on top.
//
// Dart runs one thing at a time, so every call changes what Core holds at once, in order. Only the disk and the
// network wait: writes are queued and coalesced by file, and a request's answer comes back as a later call.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'event.dart';
import 'ids.dart';
import 'rules.dart';
import 'settings.dart';
import 'store.dart';
import 'warning.dart';

// Sends one batch body and answers with the HTTP status, or null when no answer came back (offline, timed out).
typedef Sender = Future<int?> Function(String body);

// Fetches the settings file: the HTTP status and body, or nulls when no answer came back.
typedef Fetched = ({int? status, String? body});
typedef Fetcher = Future<Fetched> Function();

// What Ingest's answer means for a batch (docs/analytics-architecture.md §5).
enum Outcome {
  sent,
  dropped,
  stopped,
  retry;

  static Outcome of(int? status) => switch (status) {
        final int s when s >= 200 && s < 300 => sent,
        401 || 403 => stopped, // a bad key: sending more won't help until the app changes
        408 || 429 => retry,
        final int s when s >= 400 && s < 500 => dropped, // malformed: the same batch would fail the same way
        _ => retry, // 5xx, offline, timed out: Ingest wrote nothing, so send again
      };
}

final class Core {
  Core({
    required this.key,
    required Store store,
    required Sender send,
    required Fetcher fetch,
    DateTime Function()? now,
    double Function()? random,
    Random? ids,
  })  : _store = store,
        _sender = send,
        _fetcher = fetch,
        _now = now ?? DateTime.now,
        _random = random ?? Random().nextDouble,
        _idRandom = ids ?? Random.secure(),
        _ids = UuidV7(ids) {
    _openedAt = _now();
  }

  static const flushAt = 20; // queued events that trigger a send
  static const maxQueued = 1000; // past this, the oldest are dropped
  static const sessionTimeout = Duration(minutes: 30); // idle this long and the next event starts a new session
  static const maxErrors = 10; // $error events per launch, so an error in a build loop isn't thousands of events

  // The files in the store.
  static const queueFile = 'queue.json';
  static const stateFile = 'state.json'; // anon_id, user_id, session_id, last_active_ms
  static const settingsFile = 'settings.json'; // the last good settings file, as Ingest sent it
  static const markerFile = 'session.json';

  final String key;
  final Store _store;
  final Sender _sender;
  final Fetcher _fetcher;
  final DateTime Function() _now;
  final double Function() _random;
  final Random _idRandom;
  final UuidV7 _ids;
  late final DateTime _openedAt;

  // Calls made before the stored state is read, run in order once it is.
  var _opened = false;
  final _pending = <void Function()>[];

  // Who and when, kept across launches.
  var _context = const Context();
  var _anonId = '';
  String? _userId;
  String? _sessionId;
  DateTime? _lastActive;

  var _events = <Event>[]; // oldest first, mirrored to queue.json
  String? _screen;
  var _active = false;
  var _errors = 0;
  Set<String>? _inFlight; // the ids in the batch being sent
  var _failures = 0;
  var _retryAt = DateTime.fromMillisecondsSinceEpoch(0);
  var _stopped = false; // Ingest refused the key
  final _whenIdle = <void Function()>[];

  var _settings = Settings.defaults;
  final _exposed = <String>{}; // the switches this launch has sent $exposure for
  var _settingsDue = DateTime.fromMillisecondsSinceEpoch(0);
  var _fetching = false;

  // ---------- calls ----------
  // Each takes the time when it's called, so a call made before the state is read keeps its own time.

  void track(String name, Map<String, Object?> props) {
    if (!isName(name)) return warn(Warning.badName);
    final kept = _checked(props);
    final time = _now();
    _whenOpen(() => _record(name, kept, time));
  }

  void identify(String userId) {
    if (!isId(userId)) return warn(Warning.badUserId);
    final time = _now();
    _whenOpen(() {
      if (userId == _userId) return; // apps call identify on every launch; only a change is news
      _userId = userId;
      _saveState();
      _record(r'$identify', const {}, time);
    });
  }

  // Signed out: the next person on this device gets a new anon_id and session, tied to nothing that came before.
  void reset() {
    _whenOpen(() {
      _userId = null;
      _sessionId = null;
      _anonId = uuidV4(_idRandom);
      _saveState();
    });
  }

  // The screen also goes on every later event's context, the way page_path does on the web.
  void screen(String name) {
    if (!isContextValue(name)) return warn(Warning.badScreen);
    final time = _now();
    _whenOpen(() {
      _screen = name;
      _record(r'$screen', const {}, time);
    });
  }

  // Sent only while the settings file switches the probe on, at its share, with only the props it lists.
  void probe(String name, Map<String, Object?> props) {
    if (!isProbeName(name)) return warn(Warning.badProbe);
    final kept = _checked(props);
    final time = _now();
    _whenOpen(() {
      final probe = _settings.probe(name, kept);
      if (probe != null) _record(name, probe.props, time, rate: probe.rate);
    });
  }

  // The variant of a switch this person gets: the first (what people had before) while it's off, unknown or not
  // fetched yet, and "control" before the stored state is read. The first time this launch reads a switch that's on,
  // $exposure says who saw which side.
  String variant(String key) {
    final sw = _opened ? _settings.switches[key] : null;
    if (sw == null) return 'control';
    if (!sw.on) return sw.variants.first;
    final v = sw.variantOf(sw.unit == SwitchUnit.person ? (_userId ?? _anonId) : _anonId);
    if (_exposed.add(key)) _record(r'$exposure', {'switch': key, 'variant': v}, _now());
    return v;
  }

  // An uncaught error: its message only, at most 200 characters.
  void error(String message) {
    final time = _now();
    _whenOpen(() {
      if (_errors++ >= maxErrors) return;
      _record(r'$error', {'message': String.fromCharCodes(message.runes.take(200))}, time);
    });
  }

  void flush() {
    final time = _now();
    _whenOpen(() {
      _refreshSettings(time);
      _send(time);
    });
  }

  // ---------- the app's lifecycle ----------

  // The app came to the front: $app_open, a new session if the last one went idle, and a marker that says a session
  // is open, removed again when the app leaves the front. A marker found at the next start means it died in front.
  void becameActive() {
    final time = _now();
    _whenOpen(() {
      _active = true;
      _record(r'$app_open', const {}, time);
      _refreshSettings(time);
    });
  }

  // The session closed cleanly, and what's queued goes now. The future completes once no request is in flight.
  Future<void> enteredBackground() {
    final time = _now();
    final done = Completer<void>();
    _whenOpen(() {
      _active = false;
      _touch(time);
      _saveState();
      _removeMarker();
      _send(time);
      if (_inFlight == null) {
        done.complete();
      } else {
        _whenIdle.add(done.complete);
      }
    });
    return done.future;
  }

  void willTerminate() {
    _whenOpen(() {
      _active = false;
      _removeMarker();
    });
  }

  // For tests: what's queued, the settings in force, and a future that completes once everything is written.
  List<Event> get queued => List.unmodifiable(_events);
  Settings get current => _settings;
  Future<void> get saved => _writing ?? Future.value();

  // ---------- opening ----------

  // At start: the device's id, the queue from last time, the last good settings, and a crash if the last session
  // never closed. Then the calls made meanwhile.
  Future<void> open(Context context) async {
    _context = context;
    final time = _openedAt;
    final [state, queue, settings, marker] = await Future.wait([
      _readOrNull(stateFile),
      _readOrNull(queueFile),
      _readOrNull(settingsFile),
      _readOrNull(markerFile),
    ]);

    final stored = _decode(state);
    String? text(Object? value) => value is String ? value : null;
    final storedAnonId = text(stored['anon_id']);
    _anonId = storedAnonId ?? uuidV4(_idRandom);
    _userId = text(stored['user_id']);
    _sessionId = text(stored['session_id']);
    final lastMs = stored['last_active_ms'];
    _lastActive = lastMs is int ? DateTime.fromMillisecondsSinceEpoch(lastMs) : null;
    _events = _loadQueue(queue);
    if (settings != null) _settings = Settings.parse(settings) ?? Settings.defaults;

    final left = _decode(marker);
    if (left case {'session_id': final String session, 'last_active_ms': final int ms}) {
      _removeMarker();
      _append(r'$crash', const {}, session, DateTime.fromMillisecondsSinceEpoch(ms));
      _saveQueue();
    }
    if (storedAnonId == null) {
      _saveState();
      _record(r'$first_open', const {}, time);
    }
    _refreshSettings(time);

    _opened = true;
    for (final call in _pending) {
      call();
    }
    _pending.clear();
  }

  void _whenOpen(void Function() call) => _opened ? call() : _pending.add(call);

  // ---------- recording ----------

  Map<String, Object> _checked(Map<String, Object?> props) {
    final (:kept, :problems) = checkProps(props);
    problems.forEach(warn);
    return kept;
  }

  void _record(String name, Map<String, Object> props, DateTime time, {double? rate}) {
    final String session;
    final current = _sessionId;
    final last = _lastActive;
    if (current != null && last != null && time.difference(last) <= sessionTimeout) {
      session = current;
    } else {
      session = uuidV4(_idRandom);
      _sessionId = session;
      _append(r'$session_start', const {}, session, time);
    }
    _append(name, props, session, time, rate: rate);
    _touch(time);
    _saveState();
    if (_active) _writeMarker(session, time);
    _saveQueue();
    if (_events.length >= flushAt) _send(time);
  }

  // Sampled here, so every event is (docs/telemetry.md §2): kept at the settings' share for its name, or at a probe's
  // own share, which replaces it as in the other SDKs (§4). A kept event carries the share it was kept at, so counts can
  // divide by it.
  void _append(String name, Map<String, Object> props, String session, DateTime time, {double? rate}) {
    final share = rate ?? _settings.rate(name);
    if (!Settings.keeps(share, _random)) return;
    _events.add(Event(
      id: _ids.next(time),
      name: name,
      time: Event.timeOf(time),
      anonId: _anonId,
      userId: _userId,
      sessionId: session,
      props: props,
      context: _context.withScreen(_screen),
      sample: share < 1 ? share : null,
    ));
    if (_events.length > maxQueued) _events.removeRange(0, _events.length - maxQueued);
  }

  void _touch(DateTime time) => _lastActive = time;

  // ---------- the settings file ----------

  // Fetched at start, then again once `ttl` has passed, checked when the app comes to the front and on each flush
  // (every 10 seconds in front). One fetch at a time; a failed one keeps what's in force and waits out the ttl again.
  void _refreshSettings(DateTime time) {
    if (_stopped || _fetching || time.isBefore(_settingsDue)) return;
    _fetching = true;
    // A fetcher that throws is a fetch with no answer.
    _fetcher().then(_settingsArrived, onError: (Object _) => _settingsArrived((status: null, body: null)));
  }

  void _settingsArrived(Fetched answer) {
    _fetching = false;
    final body = answer.body;
    if (answer.status == 200 && body != null) {
      final parsed = Settings.parse(body);
      if (parsed != null) {
        _settings = parsed;
        _write(settingsFile, body);
      } else {
        warn(Warning.badSettings);
      }
    }
    _settingsDue = _now().add(Duration(seconds: _settings.ttl));
  }

  // ---------- sending ----------

  // 10 seconds after the first failure, doubling to at most 10 minutes.
  static Duration backoff(int failures) => Duration(seconds: min(10 * pow(2, max(failures - 1, 0)).toInt(), 600));

  void _send(DateTime time) {
    if (_stopped || _inFlight != null || _events.isEmpty || time.isBefore(_retryAt)) return;
    final batch = batchBody(key, _events, time);
    _inFlight = {for (final e in _events.take(batch.count)) e.id};
    // A sender that throws is a send with no answer: Ingest wrote nothing, so the batch is tried again.
    _sender(batch.body).then((status) => _finish(Outcome.of(status)), onError: (Object _) => _finish(Outcome.retry));
  }

  void _finish(Outcome outcome) {
    final batch = _inFlight ?? const <String>{};
    _inFlight = null;
    switch (outcome) {
      case Outcome.sent:
        _failures = 0;
        _retryAt = DateTime.fromMillisecondsSinceEpoch(0);
      case Outcome.dropped:
        warn(Warning.refused);
      case Outcome.stopped:
        _stopped = true;
        warn(Warning.badCredentials);
      case Outcome.retry:
        _failures++;
        _retryAt = _now().add(backoff(_failures));
    }
    if (outcome != Outcome.retry) {
      // By id, not position: the oldest may have been dropped past the cap while the batch was out.
      _events.removeWhere((e) => batch.contains(e.id));
      _saveQueue();
      if (_events.length >= flushAt) _send(_now());
    }
    if (_inFlight == null) {
      final waiting = [..._whenIdle];
      _whenIdle.clear();
      for (final done in waiting) {
        done();
      }
    }
  }

  // ---------- files ----------
  // Writes go one at a time, newest text per file: a burst of events is one write of the queue, not one per event.

  final _dirty = <String, String?>{}; // file -> its new text, or null to remove it
  Future<void>? _writing;

  void _write(String name, String? text) {
    _dirty[name] = text;
    _writing ??= _drain();
  }

  Future<void> _drain() async {
    while (_dirty.isNotEmpty) {
      final name = _dirty.keys.first;
      final text = _dirty.remove(name);
      try {
        await (text == null ? _store.remove(name) : _store.write(name, text));
      } on Object {
        warn(name == markerFile ? Warning.noMarker : Warning.unwritable);
      }
    }
    _writing = null;
  }

  // A file that can't be read is one that isn't there; a queue that won't parse is dropped, with a warning.
  Future<String?> _readOrNull(String name) async {
    try {
      return await _store.read(name);
    } on Object {
      warn(Warning.unreadable);
      return null;
    }
  }

  void _saveQueue() => _write(queueFile, jsonEncode([for (final e in _events) e.toJson()]));

  void _saveState() => _write(
      stateFile,
      jsonEncode({
        'anon_id': _anonId,
        'user_id': _userId,
        'session_id': _sessionId,
        'last_active_ms': _lastActive?.millisecondsSinceEpoch,
      }));

  List<Event> _loadQueue(String? text) {
    if (text == null) return [];
    try {
      final raw = jsonDecode(text);
      if (raw is! List<Object?>) throw const FormatException('the queue is not a list');
      return [for (final e in raw) Event.fromJson(e)];
    } on FormatException {
      warn(Warning.unreadable);
      return [];
    }
  }

  // Writes are atomic, so a file that won't read is one we never finished; it's treated as missing.
  static Map<String, Object?> _decode(String? text) {
    if (text == null) return const {};
    try {
      final raw = jsonDecode(text);
      return raw is Map<String, Object?> ? raw : const {};
    } on FormatException {
      return const {}; // never a whole file we wrote: as if there were none
    }
  }

  // The "session open" marker: which session, and when it was last known to be alive, in Unix milliseconds.
  void _writeMarker(String session, DateTime time) =>
      _write(markerFile, jsonEncode({'session_id': session, 'last_active_ms': time.millisecondsSinceEpoch}));

  void _removeMarker() => _write(markerFile, null);
}
