// Every warning the SDK logs, as one table. Each is logged once per launch, so a bad call in a loop says so once
// instead of flooding the console, and nothing the SDK drops is dropped silently.

import 'dart:developer' as developer;

enum Warning {
  notStarted('Call Bellwether.start(key) first. This call was ignored.'),
  startedTwice('Bellwether.start was called again. The second call was ignored.'),
  badKey("The key must be the app's public key: bw_pk_ then 24 to 64 letters and digits. Bellwether isn't running."),
  badName('An event name must be snake_case (a-z, 0-9 and _, starting with a letter), at most 64 characters. '
      'The event was dropped.'),
  badPropName('A property name must be snake_case, starting with a letter, at most 40 characters. '
      'The property was dropped.'),
  badPropValue('A property must be text, a number or true/false. The property was dropped.'),
  longPropValue('A text property can be at most 1,000 characters. The property was dropped.'),
  badPropNumber("A number property can't be NaN or infinite. The property was dropped."),
  tooManyProps('An event can have at most 50 properties. Past 50, only the first 50 by name were kept.'),
  badUserId('A user id must be 1 to 128 printable ASCII characters with no spaces. identify was ignored.'),
  badScreen('A screen name must be 1 to 200 characters. The screen was dropped.'),
  badProbe('A probe name must be snake_case (a-z, 0-9 and _, starting with a letter), at most 64 characters. '
      'The probe was dropped.'),
  badSettings("The settings file from Ingest couldn't be read. The last good one, or the defaults, stay in use."),
  refused('Ingest refused a batch as malformed. Its events were dropped.'),
  badCredentials('Ingest refused the key (HTTP 401 or 403). Nothing more is sent until the app restarts. '
      'Check the key.'),
  unreadable("The event queue on disk couldn't be read. The events in it were dropped."),
  unwritable("The event queue couldn't be saved to disk. Its events are lost if the app quits before they're sent."),
  unencodable("Queued events couldn't be encoded, so they were dropped. This is a bug in Bellwether."),
  noMarker("The open-session marker couldn't be written or removed, so this session's crash count may be wrong.");

  const Warning(this.message);

  final String message;
}

final _said = <Warning>{};

void warn(Warning warning) {
  if (_said.add(warning)) developer.log(warning.message, name: 'Bellwether', level: 900);
}
