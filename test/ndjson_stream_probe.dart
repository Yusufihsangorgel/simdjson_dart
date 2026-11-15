// Streams two generated NDJSON payloads and fully-decodes the larger one,
// printing the most native memory each phase held at once. Lives in a child
// process because that high-water mark covers the whole process, and
// `dart test` runs suites concurrently in one process.
//
// Run it as `dart run test/ndjson_stream_probe.dart`. It prints CHUNK_BYTES,
// then COUNT / PEAK_NATIVE_BYTES / FILE_BYTES for STREAM_SMALL, STREAM_LARGE,
// WHOLE_LARGE. The run command writes build-hook progress to stdout too, and
// the markers are what make the numbers findable.
//
// PEAK_NATIVE_BYTES counts the input copies and result tapes the shim
// holds, which is where a decode that tracked the file would show it. The
// shim counts only after sj_count_allocations turns counting on, and this
// probe does that first. This used to sample process RSS instead. That number
// also follows the Dart heap and the collector, and under Dart 3.14 the small
// stream could peak tens of megabytes above the large one.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:simdjson_dart/src/bindings.dart';

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
  sjCountAllocations(true);
  final warmup = Uint8List.fromList(
    utf8.encode('{"n":0,"p":"x"}\n{"n":1,"p":"x"}\n'),
  );
  for (var i = 0; i < 50; i++) {
    simdJsonDecodeNdjsonBytes(warmup);
  }
  await simdJsonDecodeNdjsonStream(Stream.fromIterable([warmup])).drain();

  stdout.writeln('\nCHUNK_BYTES=$_chunkSize');
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
  sjResetPeakBytes();
  var count = 0;
  var bytes = 0;
  await for (final _ in simdJsonDecodeNdjsonStream(
    _chunks(rows).map((chunk) {
      bytes += chunk.length;
      return chunk;
    }),
  )) {
    count++;
  }
  return (peak: sjPeakBytes(), count: count, bytes: bytes);
}

({int peak, int count, int bytes}) _whole(int rows) {
  final builder = BytesBuilder(copy: false);
  for (var i = 0; i < rows; i++) {
    builder.add(_line(i));
  }
  final payload = builder.takeBytes();
  sjResetPeakBytes();
  final count = simdJsonDecodeNdjsonBytes(payload).length;
  return (peak: sjPeakBytes(), count: count, bytes: payload.length);
}

void _print(String label, ({int peak, int count, int bytes}) result) {
  stdout.writeln('${label}_FILE_BYTES=${result.bytes}');
  stdout.writeln('${label}_COUNT=${result.count}');
  stdout.writeln('${label}_PEAK_NATIVE_BYTES=${result.peak}');
}
