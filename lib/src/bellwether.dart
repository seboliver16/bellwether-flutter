// The public API: start once with the app's public key, then track, probe, variant, identify, reset, screen and flush
// from anywhere. Each call hands its work to the one Core; none waits on the disk or the network. The real sender,
// settings fetcher, store and device context are made here.

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'core.dart';
import 'event.dart';
import 'hooks.dart';
import 'rules.dart';
import 'store.dart';
import 'warning.dart';

/// Bellwether's analytics. Call [start] once as the app launches; every other call is safe from anywhere after it.
abstract final class Bellwether {
  /// Where events go unless [start] is given another address. The one place it's written.
  static const defaultEndpoint = 'https://ingest.bellwetherlabs.dev';

  static Core? _core;

  /// Call once, as the app launches, with the app's public key (`bw_pk_…`). Events are posted to
  /// `{endpoint}/v1/batch`. A malformed key, or a secret `bw_sk_` one, logs a warning and starts nothing. The future
  /// completes once what the SDK kept from the last launch is read; await it before `runApp` so [variant] knows its
  /// switches from the first frame. Calls made before then are kept and run in order.
  static Future<void> start(String key, {String endpoint = defaultEndpoint}) async {
    if (_core != null) return warn(Warning.startedTwice);
    if (!isKey(key)) return warn(Warning.badKey);
    WidgetsFlutterBinding.ensureInitialized();
    final base = endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint;
    final client = http.Client();
    final core = Core(
      key: key,
      store: FileStore(getApplicationSupportDirectory().then((dir) => Directory('${dir.path}/Bellwether'))),
      send: _post(client, Uri.parse('$base/v1/batch')),
      fetch: _settings(client, Uri.parse('$base/v1/settings').replace(queryParameters: {'key': key})),
    );
    _core = core;
    Hooks(core).install();
    await core.open(await _context());
  }

  /// An event: a snake_case name, like `signup_completed`, and flat properties of text, numbers and true/false. A bad
  /// name drops the event and a bad property drops that property, each with a warning in the console.
  static void track(String name, {Map<String, Object?> props = const {}}) => _running?.track(name, props);

  /// A probe: an event written into the code but off until Bellwether needs it. It's sent only while the settings
  /// file switches `name` on, at the share of calls it asks for, with only the props it lists. Names and props follow
  /// [track]'s rules.
  static void probe(String name, {Map<String, Object?> props = const {}}) => _running?.probe(name, props);

  /// The side of a test this person is on: the switch's variant, like `'on'`. While the switch is off, unknown or not
  /// fetched yet, it's the first variant, what people had before, so code behind a switch ships dark. The first read
  /// of a switch that's on in a launch sends `$exposure`. Before [start], it's `'control'`.
  static String variant(String key) => _running?.variant(key) ?? 'control';

  /// At sign-in: your own stable id for the person, never an email. Bellwether stores only a hash of it.
  static void identify(String userId) => _running?.identify(userId);

  /// At sign-out: forgets the user id and starts a new anonymous id and session, so the next person on this device
  /// isn't tied to the last.
  static void reset() => _running?.reset();

  /// Sends `$screen` with this name, which also goes on later events as their screen. With named routes,
  /// `BellwetherNavigatorObserver` does this for you.
  static void screen(String name) => _running?.screen(name);

  /// Sends what's queued now, unless a request is already out or a failed send is waiting out its backoff.
  static void flush() => _running?.flush();

  static Core? get _running {
    if (_core == null) warn(Warning.notStarted);
    return _core;
  }

  // The real sender: one POST to {endpoint}/v1/batch. No answer within 30 seconds, or none at all, is a null status.
  static Sender _post(http.Client client, Uri url) => (body) async {
        try {
          final response = await client
              .post(url, headers: {'content-type': 'application/json'}, body: body)
              .timeout(const Duration(seconds: 30));
          return response.statusCode;
        } on Object {
          return null; // offline or timed out: Core keeps the batch and tries again
        }
      };

  // The real fetcher: GET {endpoint}/v1/settings?key=…, never answered from a cache.
  static Fetcher _settings(http.Client client, Uri url) => () async {
        try {
          final response =
              await client.get(url, headers: {'cache-control': 'no-cache'}).timeout(const Duration(seconds: 30));
          return (status: response.statusCode, body: response.body);
        } on Object {
          return (status: null, body: null); // no answer: Core keeps what's in force
        }
      };

  // This app on this device, read once at start.
  static Future<Context> _context() async {
    // A version that can't be read is a gap on these events, not a reason to stop.
    final info = await PackageInfo.fromPlatform().then<PackageInfo?>((i) => i, onError: (Object _) => null);
    final os = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : Platform.operatingSystem);
    final view = PlatformDispatcher.instance.views.firstOrNull;
    final size = view == null ? null : view.physicalSize / view.devicePixelRatio;
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    return Context(
      appVersion: info?.version,
      build: info?.buildNumber,
      os: os,
      osVersion: Context.osVersionOf(os, Platform.operatingSystemVersion),
      device: size == null ? null : (size.shortestSide >= 600 ? 'tablet' : 'phone'),
      locale: locale == 'und' ? null : locale,
    );
  }
}
