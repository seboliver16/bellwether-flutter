// The event shape Ingest accepts (docs/analytics-architecture.md §3; parseBatch in packages/analytics/src/event.ts).
// The queue on disk holds events in exactly this form, so a retry sends each event as it was made, id included.

import 'dart:convert';

import 'rules.dart';

final class Event {
  const Event({
    required this.id,
    required this.name,
    required this.time,
    required this.anonId,
    required this.userId,
    required this.sessionId,
    required this.props,
    required this.context,
    this.sample,
  });

  final String id; // a UUIDv7, made once
  final String name;
  final String time; // the device's clock: ISO 8601, UTC, milliseconds
  final String anonId;
  final String? userId;
  final String sessionId;
  final Map<String, Object> props;
  final Context context;
  final double? sample; // the share it was kept at, when it was sampled (docs/telemetry.md §2)

  // A missing user or session id is sent as null, and a missing sample is left out: absent means not sampled.
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'time': time,
        'anon_id': anonId,
        'user_id': userId,
        'session_id': sessionId,
        'props': props,
        'context': context.toJson(),
        if (sample != null) 'sample': sample,
      };

  // Reading the queue back from disk: what toJson wrote. Anything else throws, and the caller drops the queue.
  static Event fromJson(Object? raw) {
    if (raw case final Map<String, Object?> map) {
      if (map
          case {
            'id': String id,
            'name': String name,
            'time': String time,
            'anon_id': String anonId,
            'user_id': String? userId,
            'session_id': String sessionId,
            'props': Map<String, Object?> props,
            'context': Map<String, Object?> context,
          }) {
        final sample = map['sample'];
        return Event(
          id: id,
          name: name,
          time: time,
          anonId: anonId,
          userId: userId,
          sessionId: sessionId,
          props: {
            for (final MapEntry(:key, :value) in props.entries)
              if (value != null) key: value
          },
          context: Context.fromJson(context),
          sample: sample is num ? sample.toDouble() : null,
        );
      }
    }
    throw const FormatException('not a queued event');
  }

  // ISO 8601 from whole milliseconds, in UTC.
  static String timeOf(DateTime time) =>
      DateTime.fromMillisecondsSinceEpoch(time.millisecondsSinceEpoch, isUtc: true).toIso8601String();
}

// What the SDK knows about the app and device. Every key is one of CONTEXT_KEYS; a null value is left out.
final class Context {
  const Context({this.appVersion, this.build, this.os, this.osVersion, this.device, this.locale, this.screen});

  final String? appVersion;
  final String? build;
  final String? os; // iOS or Android
  final String? osVersion;
  final String? device; // phone or tablet
  final String? locale; // BCP 47, like en-GB
  final String? screen; // the last screen shown, set by Bellwether.screen

  Context withScreen(String? screen) => Context(
        appVersion: appVersion,
        build: build,
        os: os,
        osVersion: osVersion,
        device: device,
        locale: locale,
        screen: screen,
      );

  // A value Ingest would refuse (empty, or over 200 characters) is left out, so one odd version never costs an event.
  Map<String, String> toJson() => {
        for (final (key, value) in [
          ('app_version', appVersion),
          ('build', build),
          ('os', os),
          ('os_version', osVersion),
          ('device', device),
          ('locale', locale),
          ('screen', screen),
        ])
          if (value != null && isContextValue(value)) key: value,
      };

  static Context fromJson(Map<String, Object?> raw) {
    String? at(String key) => switch (raw[key]) { String value => value, _ => null };
    return Context(
      appVersion: at('app_version'),
      build: at('build'),
      os: at('os'),
      osVersion: at('os_version'),
      device: at('device'),
      locale: at('locale'),
      screen: at('screen'),
    );
  }

  // The OS version in what Dart reports: iOS's "Version 18.1 (Build 22B83)" holds it. Android's is the kernel's, so
  // it's left out rather than sent wrong.
  static String? osVersionOf(String os, String reported) =>
      os == 'iOS' ? RegExp(r'\d+(\.\d+)+').firstMatch(reported)?.group(0) : null;
}

// One POST to {endpoint}/v1/batch.
const sdk = 'flutter/0.1.0';

// The body for the oldest events that fit in one batch: at most 500 events and 512,000 bytes. Halving is enough; the
// largest event the rules allow is far under the byte limit.
({String body, int count}) batchBody(String key, List<Event> events, DateTime sentAt) {
  var count = events.length < maxEvents ? events.length : maxEvents;
  while (true) {
    final body = jsonEncode({
      'key': key,
      'sent_at': Event.timeOf(sentAt),
      'sdk': sdk,
      'events': [for (final e in events.take(count)) e.toJson()],
    });
    if (utf8.encode(body).length <= maxBytes || count == 1) return (body: body, count: count);
    count ~/= 2;
  }
}
