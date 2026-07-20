// Finds the payload size where the lazy path starts to pay for itself.
//
// simdjson is fast, but crossing the FFI boundary and copying the bytes to
// native memory is not free, so on a tiny payload dart:convert wins and on a
// larger one simdjson does. This measures the case the package is really for:
// reading a few fields out of a payload without decoding the rest. Both engines
// do the same work at each size, read the same handful of fields, so the ratio
// is a fair one, and the crossover is where SimdJsonDocument.at overtakes
// jsonDecode-then-read.
//
// For the other path, decoding a whole document, see bench/bench.dart and the
// README: that is a different, payload-dependent story, and dart:convert often
// wins there.
//
// Run with: dart run bench/crossover.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';

/// Builds an api-like object of roughly [targetBytes]: a list of records, each
/// with a few fields, wrapped in some metadata.
Uint8List _payload(int targetBytes) {
  final items = StringBuffer('{"meta":{"total":0},"items":[');
  var count = 0;
  // One record is about 90 bytes; size the list to hit the target.
  final records = (targetBytes / 90).ceil();
  for (var i = 0; i < records; i++) {
    if (i > 0) items.write(',');
    items.write('{"id":$i,"name":"item-$i","price":${(i * 3) % 1000}.99,'
        '"active":${i.isEven},"tags":["a","b"]}');
    count++;
  }
  items.write(']}');
  final json = items
      .toString()
      .replaceFirst('"total":0', '"total":$count');
  return Uint8List.fromList(utf8.encode(json));
}

/// Median milliseconds over [runs] timed iterations of [work], after warming up.
double _median(void Function() work, {required int runs}) {
  for (var i = 0; i < 5; i++) {
    work();
  }
  final times = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    work();
    sw.stop();
    times.add(sw.elapsedMicroseconds / 1000.0);
  }
  times.sort();
  return times[times.length ~/ 2];
}

void main() {
  const sizes = [
    1024,
    4 * 1024,
    16 * 1024,
    64 * 1024,
    256 * 1024,
    1024 * 1024,
    4 * 1024 * 1024,
  ];

  print('Median ms to read 2 fields out of the payload. Both engines read the '
      'same fields.\n');
  print('${'payload'.padRight(10)}${'jsonDecode'.padRight(13)}'
      '${'simd .at'.padRight(11)}winner');
  print('-' * 45);

  for (final size in sizes) {
    final bytes = _payload(size);
    final asString = utf8.decode(bytes);
    // The same two fields, read through each engine.
    const pointers = ['/meta/total', '/items/0/name'];

    // Runs scale down as payloads grow so the sweep stays quick.
    final runs = size <= 64 * 1024 ? 2000 : (size <= 1024 * 1024 ? 200 : 40);

    final convert = _median(() {
      final map = jsonDecode(asString) as Map<String, Object?>;
      (map['meta']! as Map)['total'];
      ((map['items']! as List)[0] as Map)['name'];
    }, runs: runs);

    final simd = _median(() {
      final doc = SimdJsonDocument.parseBytes(bytes);
      try {
        for (final p in pointers) {
          doc.at(p);
        }
      } finally {
        doc.close();
      }
    }, runs: runs);

    final ratio = convert / simd;
    final winner = ratio >= 1
        ? 'simd ${ratio.toStringAsFixed(1)}x'
        : 'dart:convert ${(simd / convert).toStringAsFixed(1)}x';

    print('${_human(size).padRight(10)}'
        '${convert.toStringAsFixed(3).padRight(13)}'
        '${simd.toStringAsFixed(3).padRight(11)}$winner');
  }

  print('\nThe crossover is where simd .at overtakes jsonDecode. Below it the '
      'FFI\ncost dominates and dart:convert wins; above it simdjson pulls away, '
      'because\nit never turns the fields you skip into Dart objects.');
}

String _human(int bytes) {
  if (bytes >= 1024 * 1024) return '${bytes ~/ (1024 * 1024)} MB';
  return '${bytes ~/ 1024} KB';
}
