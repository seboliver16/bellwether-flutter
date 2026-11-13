// Ids. Events get UUIDv7 (RFC 9562), lowercase: the first 48 bits are the Unix time in milliseconds, so ids sort by
// when they were made. Within one millisecond, or if the clock steps back, the 12-bit counter in rand_a keeps them in
// order (RFC 9562 §6.2, method 1); the last 62 bits are random. The device and its sessions get random UUIDv4s.

import 'dart:math';

final class UuidV7 {
  UuidV7([Random? random]) : _random = random ?? Random.secure();

  final Random _random;
  var _lastMs = -1;
  var _counter = 0;

  String next(DateTime time) {
    var ms = max(time.millisecondsSinceEpoch, 0);
    if (ms <= _lastMs) {
      ms = _lastMs;
      _counter++;
      if (_counter > 0xfff) {
        // 4,096 ids in one millisecond: borrow the next one
        ms++;
        _counter = 0;
      }
    } else {
      _counter = _random.nextInt(0x800); // a random start with the top bit clear leaves room to count
    }
    _lastMs = ms;

    final bytes = List<int>.filled(16, 0);
    for (var i = 0; i < 6; i++) {
      bytes[i] = (ms >> (8 * (5 - i))) & 0xff;
    }
    bytes[6] = 0x70 | (_counter >> 8); // version 7
    bytes[7] = _counter & 0xff;
    for (var i = 8; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    bytes[8] = 0x80 | (bytes[8] & 0x3f); // variant 10
    return _format(bytes);
  }
}

String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = 0x40 | (bytes[6] & 0x0f);
  bytes[8] = 0x80 | (bytes[8] & 0x3f);
  return _format(bytes);
}

String _format(List<int> bytes) {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
