// Measures what it costs to be told "no".
//
// The decode benchmarks all assume the document parses. A parser that sits in
// front of mixed input does not get that: some of what arrives is not strict
// JSON at all, and every one of those pays for a rejection instead of a
// result. That cost is easy to assume away, because a document that is invalid
// at byte two feels like it should be rejected in constant time.
//
// It is not. The bytes are encoded and copied across the FFI boundary before
// native simdjson ever looks at them, so a rejection scales with the size of
// the document, not with the distance to the error. This measures how steep
// that is, and how much of it is the UTF-8 encode that `simdJsonDecode` does
// on the caller's behalf.
//
// The third column is not the same work as the other two: it is a heuristic
// over the head of the string, not a parse, and it can be wrong in both
// directions. It is here because it is what a caller in front of mixed input
// actually reaches for, and the gap explains why.
//
// Run with: dart run bench/reject.dart
import 'dart:convert';

import 'package:simdjson_dart/simdjson_dart.dart';

/// An api-like document of roughly [records] entries, valid JSON.
String _valid(int records) {
  final b = StringBuffer('{"meta":{"total":$records},"items":[');
  for (var i = 0; i < records; i++) {
    if (i > 0) b.write(',');
    b.write('{"id":$i,"name":"item$i","ok":true}');
  }
  b.write(']}');
  return b.toString();
}

double _bench(void Function() body, {int reps = 300}) {
  for (var i = 0; i < 30; i++) {
    try {
      body();
    } catch (_) {}
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < reps; i++) {
    try {
      body();
    } catch (_) {}
  }
  sw.stop();
  return sw.elapsedMicroseconds / reps;
}

void main() {
  print('Cost of rejecting a document that is invalid at byte two.\n');
  print(
    '${'size'.padLeft(10)}  ${'decode(String)'.padLeft(15)}'
    '  ${'decodeBytes'.padLeft(12)}  ${'head scan'.padLeft(10)}',
  );

  for (final records in [100, 1000, 10000, 100000]) {
    final valid = _valid(records);
    // Invalid immediately: a comma where a key must start.
    final invalid = '{,${valid.substring(1)}';
    final invalidBytes = utf8.encode(invalid);

    final asString = _bench(() => simdJsonDecode(invalid));
    final asBytes = _bench(() => simdJsonDecodeBytes(invalidBytes));
    // What a caller does instead: look at the head and skip the attempt.
    final scan = _bench(() {
      final head = invalid.length > 4096 ? invalid.substring(0, 4096) : invalid;
      head.contains('/*') || head.contains("'");
    });

    print(
      '${_size(invalid.length).padLeft(10)}'
      '  ${asString.toStringAsFixed(1).padLeft(13)} µs'
      '  ${asBytes.toStringAsFixed(1).padLeft(10)} µs'
      '  ${scan.toStringAsFixed(1).padLeft(8)} µs',
    );
  }

  print(
    '\nRejection is not constant time: it grows with the document, because the\n'
    'input is marshalled before it is parsed. Most of the difference between\n'
    'the first two columns is the UTF-8 encode inside simdJsonDecode, so a\n'
    'caller that already holds bytes should hand them over directly.',
  );
}

String _size(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).round()} KB';
}
