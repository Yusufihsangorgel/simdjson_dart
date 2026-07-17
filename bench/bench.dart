// Compares simdJsonDecode against dart:convert's jsonDecode on synthetic
// workloads. Run with: dart run bench/bench.dart
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:simdjson/simdjson.dart';

void main() {
  final workloads = <String, (String, List<String>)>{
    'api-like objects (~8 MB)': (
      _apiLike(),
      ['/items/0/name', '/items/20000/price', '/items/39999/nested/rank'],
    ),
    'number-heavy arrays (~6 MB)': (
      _numberHeavy(),
      ['/0/0', '/60000/1', '/119999/4'],
    ),
    'string-heavy (~6 MB)': (_stringHeavy(), ['/0', '/30000', '/59999']),
  };

  for (final entry in workloads.entries) {
    final name = entry.key;
    final (json, pointers) = entry.value;
    final bytes = Uint8List.fromList(utf8.encode(json));
    print('== $name (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');

    final convertFromString = _measure(
      () => jsonDecode(json),
      warmup: 3,
      runs: 10,
    );
    final convertFromBytes = _measure(
      () => jsonDecode(utf8.decode(bytes)),
      warmup: 3,
      runs: 10,
    );
    final simdFromString = _measure(
      () => simdJsonDecode(json),
      warmup: 3,
      runs: 10,
    );
    final simdFromBytes = _measure(
      () => simdJsonDecodeBytes(bytes),
      warmup: 3,
      runs: 10,
    );

    print('  decode only:');
    print('  jsonDecode(String)          ${_fmt(convertFromString, bytes)}');
    print('  jsonDecode(utf8.decode(b))  ${_fmt(convertFromBytes, bytes)}');
    print(
      '  simdJsonDecode(String)      ${_fmt(simdFromString, bytes)}'
      '  (${(convertFromString / simdFromString).toStringAsFixed(2)}x)',
    );
    print(
      '  simdJsonDecodeBytes(bytes)  ${_fmt(simdFromBytes, bytes)}'
      '  (${(convertFromBytes / simdFromBytes).toStringAsFixed(2)}x vs '
      'decode-from-bytes)',
    );

    // dart:convert returns lazily materialized maps; real code reads the
    // data, so decode + full traversal is the fairer comparison.
    final convertTouch = _measure(
      () => _touch(jsonDecode(utf8.decode(bytes))),
      warmup: 3,
      runs: 10,
    );
    final simdTouch = _measure(
      () => _touch(simdJsonDecodeBytes(bytes)),
      warmup: 3,
      runs: 10,
    );
    print('  decode + read every field (from bytes):');
    print('  jsonDecode                  ${_fmt(convertTouch, bytes)}');
    print(
      '  simdJsonDecodeBytes         ${_fmt(simdTouch, bytes)}'
      '  (${(convertTouch / simdTouch).toStringAsFixed(2)}x)',
    );

    // Selective access: read three scattered values out of the document.
    final convertPick = _measure(
      () {
        final decoded = jsonDecode(utf8.decode(bytes));
        return [for (final p in pointers) _resolve(decoded, p)];
      },
      warmup: 3,
      runs: 10,
    );
    final simdPick = _measure(
      () {
        final doc = SimdJsonDocument.parseBytes(bytes);
        try {
          return [for (final p in pointers) doc.at(p)];
        } finally {
          doc.close();
        }
      },
      warmup: 3,
      runs: 10,
    );
    print('  read 3 values only (from bytes):');
    print('  jsonDecode + index          ${_fmt(convertPick, bytes)}');
    print(
      '  SimdJsonDocument.at         ${_fmt(simdPick, bytes)}'
      '  (${(convertPick / simdPick).toStringAsFixed(2)}x)',
    );
    print('');
  }
}

/// Minimal JSON Pointer resolution over decoded Dart objects.
Object? _resolve(Object? node, String pointer) {
  var current = node;
  for (final token in pointer.split('/').skip(1)) {
    switch (current) {
      case Map map:
        current = map[token];
      case List list:
        current = list[int.parse(token)];
      default:
        return null;
    }
  }
  return current;
}

/// Forces materialization by visiting every value.
int _touch(Object? node) {
  var sum = 0;
  switch (node) {
    case Map<String, dynamic> map:
      for (final value in map.values) {
        sum += _touch(value);
      }
    case List list:
      for (final value in list) {
        sum += _touch(value);
      }
    case String s:
      sum += s.length;
    case int i:
      sum += i & 0xff;
    case double d:
      sum += d.isFinite ? 1 : 0;
    case bool b:
      sum += b ? 1 : 0;
    case null:
      sum += 0;
  }
  return sum;
}

/// Median wall time in microseconds.
double _measure(
  Object? Function() body, {
  required int warmup,
  required int runs,
}) {
  for (var i = 0; i < warmup; i++) {
    body();
  }
  final times = <int>[];
  final watch = Stopwatch();
  for (var i = 0; i < runs; i++) {
    watch
      ..reset()
      ..start();
    body();
    watch.stop();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2].toDouble();
}

String _fmt(double micros, Uint8List bytes) {
  final mbPerSec = bytes.length / micros; // bytes/us == MB/s
  return '${(micros / 1000).toStringAsFixed(1).padLeft(8)} ms  '
      '${mbPerSec.toStringAsFixed(0).padLeft(5)} MB/s';
}

String _apiLike() {
  final random = Random(42);
  final items = [
    for (var i = 0; i < 40000; i++)
      {
        'id': i,
        'uuid': 'u-${random.nextInt(1 << 30)}-$i',
        'name': 'Item number $i with a plausible title',
        'price': random.nextDouble() * 100,
        'quantity': random.nextInt(1000),
        'active': i.isEven,
        'tags': ['alpha', 'beta', 'gamma'],
        'nested': {
          'rank': i % 17,
          'score': random.nextDouble(),
          'note': i % 3 == 0 ? null : 'note-$i',
        },
      },
  ];
  return jsonEncode({'items': items});
}

String _numberHeavy() {
  final random = Random(7);
  final rows = [
    for (var i = 0; i < 120000; i++)
      [
        i,
        random.nextDouble() * 1e6,
        random.nextDouble() * 1e-6,
        random.nextInt(1 << 31),
        random.nextDouble(),
      ],
  ];
  return jsonEncode(rows);
}

String _stringHeavy() {
  final words = [
    for (var i = 0; i < 60000; i++)
      'The quick brown fox number $i jumps over the lazy dog with '
          'çğış ve 雪 unicode content mixed in for realism.',
  ];
  return jsonEncode(words);
}
