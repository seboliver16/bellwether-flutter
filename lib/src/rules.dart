// The rules Ingest applies to every event (parseBatch in packages/analytics/src/event.ts), checked on the device first
// so a bad name or property is dropped here, with a warning, before Ingest refuses the event. Keep the two in step.

import 'warning.dart';

const maxEvents = 500; // per batch
const maxBytes = 512000; // per batch body
const maxProps = 50; // keys per event
const maxValue = 1000; // characters per text property, counted as JavaScript does (UTF-16), as Dart does too
const maxContext = 200; // characters per context value

// Our own events. A name starting with $ must be one of these (AUTO_EVENTS).
const autoEvents = {
  r'$pageview',
  r'$screen',
  r'$session_start',
  r'$app_open',
  r'$first_open',
  r'$identify',
  r'$error',
  r'$vitals',
  r'$crash',
  r'$exposure',
  r'$tap',
  r'$request',
};

final _eventName = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final _propName = RegExp(r'^[a-z][a-z0-9_]{0,39}$');
final _key = RegExp(r'^bw_pk_[A-Za-z0-9]{24,64}$');

bool isName(String name) => _eventName.hasMatch(name) || autoEvents.contains(name);

// A probe is the app's own event, switched on by the settings file, so it never takes one of our $ names.
bool isProbeName(String name) => _eventName.hasMatch(name);

// Printable ASCII with no spaces, 1 to 128 characters: anon_id, user_id and session_id.
bool isId(String id) => id.isNotEmpty && id.length <= 128 && id.codeUnits.every((c) => c >= 0x21 && c <= 0x7e);

// A public key. A secret bw_sk_ key never belongs in an app.
bool isKey(String key) => _key.hasMatch(key);

bool isContextValue(String value) => value.isNotEmpty && value.length <= maxContext;

// The properties Ingest would keep, and what was wrong with the rest. Past 50 keys, the first 50 by name are kept, so
// the same call always keeps the same ones.
({Map<String, Object> kept, Set<Warning> problems}) checkProps(Map<String, Object?> raw) {
  final kept = <String, Object>{};
  final problems = <Warning>{};
  for (final key in raw.keys.toList()..sort()) {
    final value = raw[key];
    final problem = switch (value) {
      _ when !_propName.hasMatch(key) => Warning.badPropName,
      String text when text.length > maxValue => Warning.longPropValue,
      num number when !number.isFinite => Warning.badPropNumber,
      String() || num() || bool() => kept.length == maxProps ? Warning.tooManyProps : null,
      _ => Warning.badPropValue,
    };
    if (problem != null) {
      problems.add(problem);
    } else if (value != null) {
      kept[key] = value; // with no problem, it's text, a number or true/false
    }
  }
  return (kept: kept, problems: problems);
}
