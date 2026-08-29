// Streams two generated NDJSON payloads and fully-decodes the larger one,
// printing the RSS sampled during each phase. Lives in a child process
// because `dart test` runs suites concurrently in one process, so RSS
// measured inside a test is contaminated by whatever else is allocating.
//
// Usage: dart run test/ndjson_stream_probe.dart
// Prints COUNT / PEAK_RSS / FILE_BYTES for STREAM_SMALL, STREAM_LARGE,
// WHOLE_LARGE. `dart run` writes build-hook progress to stdout too, so
// the markers are what make the numbers findable.
//
// Lines are fat and few so the input can grow without the Dart object
// graph dominating: the thing under test is whether the *bytes* stay
// bounded. PEAK_RSS is ProcessInfo.currentRss sampled after warmup and
// then every 256 records of that phase. It is not a heap accounting of
// the decoder: it includes the VM, the JIT, and the thread-local
// parser's retained capacity. It is a proxy for "did resident size
// track the file?"
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';

const _smallRows = 4000;
const _largeRows = 20000;
const _blob =
    '0123456789abcdef0123456789abcdef'
    '0123456789abcdef0123456789abcdef'
    '0123456789abcdef0123456789abcdef'
    '0123456789abcdef0123456789abcdef'
    '0123456789abcdef0123456789abcdef'
    '0123456789abcdef0123456789abcdef'
    '0123456789abcdef0123456789abcdef'
    '0123456789abcdef0123456789abcdef'; // 256 chars
const _chunkSize = 64 * 1024;

void main() async {
  final warmup = Uint8List.fromList(
    utf8.encode('{"n":0,"p":"x"}\n{"n":1,"p":"x"}\n'),
  );
  for (var i = 0; i < 50; i++) {
    simdJsonDecodeNdjsonBytes(warmup);
  }
  await simdJsonDecodeNdjsonStream(Stream.fromIterable([warmup])).drain();

  final small = await _stream(_smallRows);
  _print('STREAM_SMALL', small);

  final large = await _stream(_largeRows);
  _print('STREAM_LARGE', large);

  final whole = _whole(_largeRows);
  _print('WHOLE_LARGE', whole);
}

Uint8List _line(int i) =>
    Uint8List.fromList(utf8.encode('{"n":$i,"p":"$_blob"}\n'));

Stream<Uint8List> _chunks(int rows) async* {
  var buffer = BytesBuilder(copy: false);
  for (var i = 0; i < rows; i++) {
    buffer.add(_line(i));
    if (buffer.length >= _chunkSize) {
      yield buffer.takeBytes();
    }
  }
  if (buffer.length != 0) {
    yield buffer.takeBytes();
  }
}

Future<({int peak, int count, int bytes})> _stream(int rows) async {
  var peak = ProcessInfo.currentRss;
  var count = 0;
  var bytes = 0;
  await for (final _ in simdJsonDecodeNdjsonStream(
    _chunks(rows).map((chunk) {
      bytes += chunk.length;
      return chunk;
    }),
  )) {
    count++;
    if (count & 0xff == 0) {
      peak = max(peak, ProcessInfo.currentRss);
    }
  }
  return (peak: max(peak, ProcessInfo.currentRss), count: count, bytes: bytes);
}

({int peak, int count, int bytes}) _whole(int rows) {
  final builder = BytesBuilder(copy: false);
  for (var i = 0; i < rows; i++) {
    builder.add(_line(i));
  }
  final payload = builder.takeBytes();
  var peak = ProcessInfo.currentRss;
  var count = 0;
  for (final _ in simdJsonDecodeNdjsonBytes(payload)) {
    count++;
    if (count & 0xff == 0) {
      peak = max(peak, ProcessInfo.currentRss);
    }
  }
  return (
    peak: max(peak, ProcessInfo.currentRss),
    count: count,
    bytes: payload.length,
  );
}

void _print(String label, ({int peak, int count, int bytes}) result) {
  stdout.writeln('${label}_FILE_BYTES=${result.bytes}');
  stdout.writeln('${label}_COUNT=${result.count}');
  stdout.writeln('${label}_PEAK_RSS=${result.peak}');
}
