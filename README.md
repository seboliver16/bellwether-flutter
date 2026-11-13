# Bellwether for Flutter

Bellwether's analytics SDK for Flutter apps on iOS and Android: a Dart package. It sends the events your code tracks,
plus a few of its own, to Bellwether's Ingest, and everything Bellwether shows is counted from them.

Flutter 3.24 or later (Dart 3.5). It depends on `http`, `path_provider` and `package_info_plus`, nothing else.

## Adding the package

It isn't on pub.dev yet. Until it is, add it from Git in `pubspec.yaml`:

```yaml
dependencies:
  bellwether:
    git:
      url: https://github.com/seboliver16/bellwether
      path: sdks/flutter
```

Once it's published, this becomes `bellwether: ^0.1.0`.

## The calls

Start once, before `runApp`, with the app's public key from Bellwether (Tools › Your apps):

```dart
import 'package:bellwether/bellwether.dart';
import 'package:flutter/foundation.dart';

Future<void> main() async {
  // release builds only, so debug sessions stay out of the counts
  if (kReleaseMode) await Bellwether.start('bw_pk_…');
  runApp(MaterialApp(
    navigatorObservers: [BellwetherNavigatorObserver()],   // $screen for each named route
    routes: { … },
  ));
}
```

`start` reads what the SDK kept from the last launch and completes in a few milliseconds; awaiting it means `variant`
knows its switches from the first frame. Calls made before it completes are kept and run in order. No call waits on
the disk or the network.

```dart
Bellwether.track('signup_completed', props: {'plan': 'pro', 'seats': 3, 'trial': true});
Bellwether.probe('cart_viewed', props: {'items': 3});   // sent only while Bellwether switches it on (below)
Bellwether.variant('reply_nudge');                      // 'control', or the side of a test this person is on
Bellwether.identify('u_123');        // at sign-in: your own stable id for the person, never an email
Bellwether.reset();                  // at sign-out
Bellwether.screen('SignUp');         // or let BellwetherNavigatorObserver name screens from routes
Bellwether.flush();                  // send now; rarely needed
```

- **Names** are snake_case, object then action: `signup_completed`, `checkout_started`. Letters a–z, digits and `_`,
  starting with a letter, at most 64 characters.
- **Properties** are flat: text (at most 1,000 characters), a number, or true/false. At most 50, with snake_case names
  of at most 40 characters. No nested values, lists or dates.
- A bad name drops the event; a bad property drops that property. Either way the console says so once, under the name
  `Bellwether`. These are the same rules Ingest applies, so nothing is refused after the trip.
- `start(key, endpoint: …)` takes another endpoint for testing. Without one, events go to
  `Bellwether.defaultEndpoint`.

## What's sent automatically

| Event | When |
|---|---|
| `$first_open` | The first time the SDK starts on this device for this app: the closest thing to an install code can see |
| `$app_open` | Each time the app comes to the front |
| `$session_start` | Before the first event of a session. A session ends after 30 minutes with no event, or 30 minutes after the app left the front |
| `$screen` | From `BellwetherNavigatorObserver` (a page route's name, when pushed, replaced or returned to) or `screen()` |
| `$identify` | When `identify` is given a new user id, tying this device's anonymous id to the person |
| `$error` | An error nobody caught, from `FlutterError.onError` and `PlatformDispatcher.onError`: its message only, at most 200 characters and 10 a launch |
| `$crash` | At the next start, for a session that was in front when the app died (below) |

Every event carries a UUIDv7 id, the device's time, the anonymous id, the user id (or null), the session id, and a
context: app version and build, `iOS` or `Android`, the iOS version, `phone` or `tablet`, the device's language (like
`en-GB`), and the last screen named. Android's version isn't sent: Dart only knows the kernel's.

**Errors** go on to whatever handled them before `start` (the console, Crashlytics, Sentry), so nothing else misses
one. Stack traces stay there; Bellwether only counts.

**Crash-free sessions without a crash reporter.** While the app is in front, the SDK keeps a small "session open"
marker (the session id and when it was last active) in the app's support folder, under `Bellwether/`. It removes the
marker when the app goes to the background or quits normally. If `start` finds a marker left from before, the app
died in front, whether from a native crash or anything else: it sends `$crash` for that session, at its last active
time. A kill by the system while in the background isn't a crash, because the marker was already gone. Stopping the
app from the debugger looks like a crash.

**Sending.** Events wait in a queue on disk (`Bellwether/queue.json`, at most the newest 1,000), and go every 10
seconds while the app is in front, as soon as 20 are waiting, and when the app goes to the background. One request is
out at a time, at most 500 events and 512 KB. Each event's id is made once, so a retry sends the same ids and nothing
is counted twice.

| Ingest answers | The SDK |
|---|---|
| 200 | removes the events it sent |
| 400 | drops the batch as malformed, never retries it, and logs it |
| 401 or 403 | drops the batch, logs once, and sends nothing more until the app restarts: check the key |
| 429, 5xx, or no answer | keeps the events and tries again after 10 seconds, doubling to at most 10 minutes |

## The settings file

Bellwether decides what's worth recording, per app, and the SDK asks it. At start, and every `ttl` seconds after
(checked when the app comes to the front and every 10 seconds while it's there), it fetches
`GET {endpoint}/v1/settings?key=…`:

```json
{
  "version": 7,
  "ttl": 600,
  "sample": { "step_viewed": 0.1 },
  "probes": { "cart_viewed": { "sample": 1, "props": ["items"] } },
  "switches": { "reply_nudge": { "variants": ["control", "on"], "split": [0.5, 0.5], "salt": "reply_nudge.1", "on": true } }
}
```

- `sample` keeps that share of an event (0 to 1), chosen at random on the device. A kept sampled event carries
  `sample`, so Bellwether's counts divide by it; missing means 1, and the field is left out.
- `probes` switches probes on. `probe(name, props:)` sends nothing unless its name is listed, then sends that share of
  calls, with only the listed `props` when there's a list. A probe's name and props follow `track`'s rules.
- `switches` split people for a test. `Bellwether.variant(key)` returns this person's side, the same in every
  Bellwether SDK for the same id: the device's anonymous id, or the signed-in person's for a switch with
  `"unit": "person"`. While a switch is off, unknown or not fetched yet it's the first variant, so code behind it ships
  dark. The first read of a switch that's on in a launch sends `$exposure`.
- `capture` is for the web and iOS SDKs' taps, clicks and requests, which this one doesn't record yet.

The last good file is kept in `Bellwether/settings.json` and used from the next start until a new one arrives. A
file that isn't JSON is ignored whole, a part of it that's malformed falls back to its default (as Ingest's own
`parseSettings` does), and a failed fetch keeps what's in force. With no file yet, nothing is sampled and every probe
and switch is off. A `ttl` outside 60 seconds to a day counts as 600.

## Privacy

- No advertising id and no tracking, so App Tracking Transparency doesn't apply.
- The anonymous id is a random id for this app on this device, kept in the app's own support folder. It's not shared
  with other apps, and `reset` replaces it.
- Errors send their message only; Ingest drops one that looks personal, like an email address.
- Ingest never keeps IP addresses, stores only a hash of the user id, and drops properties that look like personal
  data. If your app calls `identify`, events are tied to your user ids, so your App Store and Play privacy answers
  should say that data is linked to the user.

## Working on the SDK

```sh
flutter pub get
flutter test
dart analyze
```

Everything that decides something is in `Core`, plain Dart that takes its clock, randomness, store, sender and
settings fetcher as arguments, and is tested through fakes (`test/support.dart`). The Flutter wiring is thin: `Hooks`
turns the app's lifecycle and uncaught errors into Core's calls, tested against flutter_test's binding, and the
navigator observer is tested with real routes. `test/fixtures/batch.json` is the exact batch the SDK sends, written to
`parseBatch`'s rules in `packages/analytics/src/event.ts`, and `packages/analytics/test/event.test.ts` runs it through
`parseBatch`. When those rules change, change `rules.dart` and the fixture with them. The switch tests read
`sdks/conformance/switches.json` from the repository, the cases every SDK must pass exactly.

| File | What |
|---|---|
| `lib/bellwether.dart` | What an app imports: `Bellwether` and `BellwetherNavigatorObserver` |
| `lib/src/bellwether.dart` | The public calls, the default endpoint, the real sender and fetcher (http), and the device's context |
| `lib/src/core.dart` | Identity, sessions, the crash marker, the queue on disk, sending and retrying, the settings file, sampling, probes, switches |
| `lib/src/settings.dart` | The settings file: its shape, defaults and parsing, and which side of a switch an id is on |
| `lib/src/event.dart` | The event and batch shapes, and the device context |
| `lib/src/rules.dart` | Ingest's rules for names, properties, ids and keys |
| `lib/src/store.dart` | Where the SDK keeps files: the `Store` interface, and `FileStore` |
| `lib/src/ids.dart` | Event ids (UUIDv7), device and session ids |
| `lib/src/warning.dart` | Every warning the SDK logs |
| `lib/src/hooks.dart` | Flutter: front, background, quit, uncaught errors, and the 10-second timer |
| `lib/src/navigator.dart` | `BellwetherNavigatorObserver` |
