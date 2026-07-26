// Runs one allocation loop and prints the resident-set growth it caused.
//
// This lives in a separate process on purpose. `dart test` runs suites
// concurrently in one process, so resident set size measured inside a test is
// contaminated by whatever the other suites are allocating at the time -
// measured at over 500MB of unrelated growth, which is far more than the leaks
// these loops exist to detect. A child process sees only its own work.
//
// Usage: dart run test/leak_probe.dart <mode> <iterations>
// Prints: a line of the form `RSS_DELTA_MB=<megabytes>`. `dart run` writes
// build-hook progress to stdout too, so the marker is what makes the number
// findable.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

Uint8List _payload(int elements) => _bytes(
  '{"items":[${List.generate(elements, (i) => '{"id":$i,"n":"x$i"}').join(',')}]}',
);

void main(List<String> args) {
  final mode = args[0];
  final iterations = int.parse(args[1]);

  late void Function() cycle;
  var warmup = 200;

  switch (mode) {
    case 'parseBytes':
      final payload = _payload(2000);
      cycle = () => SimdJsonDocument.parseBytes(payload)
        ..at('/items')
        ..close();
    case 'decodeBytes':
      final payload = _payload(2000);
      cycle = () => simdJsonDecodeBytes(payload);
    case 'ndjson':
      final line =
          '{"items":[${List.generate(200, (i) => '{"id":$i}').join(',')}]}';
      final payload = _bytes(List.filled(20, line).join('\n'));
      warmup = 100;
      cycle = () => simdJsonDecodeNdjsonBytes(payload);
    case 'pointer':
      final key = 'k' * 32768;
      final document = SimdJsonDocument.parse('{"$key":1}');
      final pointer = '/$key';
      warmup = 100;
      cycle = () => document.at(pointer);
    default:
      throw ArgumentError('unknown mode $mode');
  }

  for (var i = 0; i < warmup; i++) {
    cycle();
  }
  final before = ProcessInfo.currentRss;
  for (var i = 0; i < iterations; i++) {
    cycle();
  }
  final grownMb = (ProcessInfo.currentRss - before) / (1024 * 1024);
  stdout.writeln('\nRSS_DELTA_MB=$grownMb');
}
