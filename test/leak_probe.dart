// Runs one allocation loop and prints how many native blocks it left alive.
//
// With counting on, the shim counts every block it hands out (input and
// result buffers, result tapes, open documents) and every block it gets back.
// Counting is off by default, and this probe turns it on before anything
// else. The difference across the loop is 0, or one block per iteration for
// each lost free.
//
// This lives in a separate process on purpose. The count covers the whole
// process, and `dart test` runs suites concurrently in one process. A child
// process sees only its own work.
//
// Run it as `dart run test/leak_probe.dart <mode> <iterations>`. It prints a
// line of the form `LIVE_DELTA=<blocks>`. The run command writes build-hook
// progress to stdout too, and the marker is what makes the number findable.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:simdjson_dart/src/bindings.dart';
import 'package:simdjson_dart/src/decoder.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

Uint8List _payload(int elements) => _bytes(
  '{"items":[${List.generate(elements, (i) => '{"id":$i,"n":"x$i"}').join(',')}]}',
);

Uint8List _malformedPayload(int elements) {
  final valid = _payload(elements);
  return Uint8List.fromList(valid.sublist(0, valid.length - 1));
}

Uint8List _malformedNdjsonPayload() {
  final line =
      '{"items":[${List.generate(200, (i) => '{"id":$i}').join(',')}]}';
  return _bytes('${List.filled(20, line).join('\n')}\n{"broken":');
}

void _expectFormat(void Function() action) {
  try {
    action();
  } on FormatException catch (error) {
    if (error.message.isEmpty) {
      throw StateError('FormatException had no diagnostic message');
    }
    return;
  }
  throw StateError('expected FormatException');
}

Future<void> _expectFormatAsync(Future<void> Function() action) async {
  try {
    await action();
  } on FormatException catch (error) {
    if (error.message.isEmpty) {
      throw StateError('FormatException had no diagnostic message');
    }
    return;
  }
  throw StateError('expected FormatException');
}

Future<void> main(List<String> args) async {
  final mode = args[0];
  final iterations = int.parse(args[1]);

  _startCounting();

  late FutureOr<void> Function() cycle;

  switch (mode) {
    case 'parseBytes':
      final payload = _payload(2000);
      cycle = () => SimdJsonDocument.parseBytes(payload)
        ..at('/items')
        ..close();
    case 'parseFailure':
      final payload = _malformedPayload(2000);
      cycle = () => _expectFormat(() => SimdJsonDocument.parseBytes(payload));
    case 'decodeBytes':
      final payload = _payload(2000);
      cycle = () => simdJsonDecodeBytes(payload);
    case 'decodeFailure':
      final payload = _malformedPayload(2000);
      cycle = () => _expectFormat(() => simdJsonDecodeBytes(payload));
    case 'ndjson':
      final line =
          '{"items":[${List.generate(200, (i) => '{"id":$i}').join(',')}]}';
      final payload = _bytes(List.filled(20, line).join('\n'));
      cycle = () => simdJsonDecodeNdjsonBytes(payload);
    case 'ndjsonFailure':
      final payload = _malformedNdjsonPayload();
      cycle = () => _expectFormat(() => simdJsonDecodeNdjsonBytes(payload));
    case 'pointer':
      final key = 'k' * 32768;
      final document = SimdJsonDocument.parse('{"$key":1}');
      final pointer = '/$key';
      cycle = () => document.at(pointer);
      // Closing it afterwards keeps the document reachable until the last
      // count is read. A finalizer could otherwise free it first.
      try {
        _report(await _liveDelta(iterations, cycle));
      } finally {
        document.close();
      }
      return;
    case 'pointerFailure':
      final document = SimdJsonDocument.parse('{"a":1}');
      final pointer = 'k' * 32768;
      cycle = () {
        _expectFormat(() => document.at(pointer));
        _expectFormat(() => document.exists(pointer));
        _expectFormat(() => document.atMany([pointer]));
      };
      try {
        _report(await _liveDelta(iterations, cycle));
      } finally {
        document.close();
      }
      return;
    case 'selectFailure':
      final line = _bytes(
        '{"items":[${List.generate(2000, (i) => '{"id":$i,"n":"x$i"}').join(',')}]}\n',
      );
      final pointer = 'k' * 32768;
      cycle = () => _expectFormatAsync(() async {
        await simdJsonSelectNdjsonStream(Stream<List<int>>.value(line), [
          pointer,
        ]).toList();
      });
    default:
      throw ArgumentError('unknown mode $mode');
  }

  _report(await _liveDelta(iterations, cycle));
}

/// How many more native blocks are alive after [iterations] calls of [cycle]
/// than before them.
Future<int> _liveDelta(int iterations, FutureOr<void> Function() cycle) async {
  final before = sjLiveAllocations();
  for (var i = 0; i < iterations; i++) {
    await cycle();
  }
  return sjLiveAllocations() - before;
}

void _report(int liveDelta) => stdout.writeln('\nLIVE_DELTA=$liveDelta');

/// Turns counting on, and throws unless the count follows blocks and
/// documents across a switch of the setting. Without this, a count that never
/// moves would pass every loop.
void _startCounting() {
  // Taken while counting is off and released while it is on. Neither may
  // move the count.
  sjCountAllocations(false);
  final quietBlock = allocateBytes(1);
  final quietDocument = SimdJsonDocument.parse('{}');
  sjCountAllocations(true);
  final start = sjLiveAllocations();
  freeBytes(quietBlock);
  quietDocument.close();
  _expectLive(start, 'after releasing what was taken with counting off');

  // Taken while counting is on and released while it is off. It adds one
  // and takes it back.
  final block = allocateBytes(1);
  _expectLive(start + 1, 'with one block held');
  sjCountAllocations(false);
  freeBytes(block);
  sjCountAllocations(true);
  _expectLive(start, 'after releasing it with counting off');

  // An open document adds one as well. Whether closing it takes that back is
  // what the parseBytes loop measures.
  final document = SimdJsonDocument.parse('{}');
  _expectLive(start + 1, 'with one document open');
  document.close();
}

void _expectLive(int expected, String when) {
  final live = sjLiveAllocations();
  if (live != expected) {
    throw StateError(
      'live allocation count was $live $when, expected $expected',
    );
  }
}
