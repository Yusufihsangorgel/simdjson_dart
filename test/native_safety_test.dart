import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

const _iterations = 1500;

/// Runs [mode] of test/leak_probe.dart in a child process and returns how
/// many more native blocks were alive after the loop than before it.
int _liveBlocksLeft(String mode) {
  final result = Process.runSync(Platform.resolvedExecutable, [
    'run',
    'test/leak_probe.dart',
    mode,
    '$_iterations',
  ]);
  expect(
    result.exitCode,
    0,
    reason: '$mode leak_probe failed: ${result.stderr}',
  );
  final reported = RegExp(
    r'LIVE_DELTA=(-?[0-9]+)',
  ).firstMatch(result.stdout as String);
  expect(
    reported,
    isNotNull,
    reason: '$mode printed no measurement: ${result.stdout}',
  );
  return int.parse(reported!.group(1)!);
}

/// The safety properties that matter for a package holding native memory:
/// misuse must raise a Dart error rather than corrupt memory, and neither the
/// closed nor the forgotten path may leak.

void main() {
  group('native safety', () {
    test('using a closed document throws instead of touching freed memory', () {
      final document = SimdJsonDocument.parseBytes(_bytes('{"a":1}'))..close();
      expect(document.isClosed, isTrue);
      expect(() => document.at('/a'), throwsStateError);
    });

    test('closing twice is safe', () {
      final document = SimdJsonDocument.parseBytes(_bytes('{"a":1}'))..close();
      expect(document.close, returnsNormally);
    });

    test('malformed input raises FormatException, never a crash', () {
      for (final bad in ['', '{', '"unterminated', '{"a":}', '[[[[[[', 'nul']) {
        expect(
          () => SimdJsonDocument.parseBytes(_bytes(bad)),
          throwsFormatException,
          reason: 'input ${jsonEncode(bad)}',
        );
      }
    });

    // Every native block these entry points allocate has to come back. The
    // shim counts the blocks it hands out (input and result buffers, result
    // tapes, open documents) and the ones it gets back, and the child process
    // (test/leak_probe.dart) reports the difference across a loop. Counting
    // is off unless something turns it on, and the child does that first. A
    // lost free leaves one block per iteration, including the fixed-size
    // result struct that the resident set could never show.
    //
    // The count sees only what crosses the C ABI. It misses Dart objects the
    // stream path keeps alive, and memory simdjson manages itself (parser
    // capacity, document_stream buffers, the vector a tape is built in before
    // it is copied out). An open document is one counted block, which is how
    // a leaked document still shows up here. A stream that buffered every
    // chunk before its first value is caught by "records from earlier chunks
    // are yielded before a later error" in test/ndjson_stream_test.dart.
    //
    // These tests used to bound resident set growth. That number also follows
    // the Dart heap and the garbage collector. Under Dart 3.14 on Linux it
    // moved by up to 65MB in either direction on loops that free every block,
    // while the C allocator's own total moved by about 3MB.
    //
    // The count covers the whole process. Since the test runner runs suites
    // concurrently in one process, each loop runs in a child.
    for (final (mode, what) in const [
      ('parseBytes', 'padded input and the tape behind at()'),
      ('decodeBytes', 'the tape and the native copy of the input'),
      ('ndjson', 'the tape and the native copy of the input'),
      ('pointer', 'the native copy of a long JSON pointer'),
    ]) {
      test('$mode releases $what', () {
        expect(
          _liveBlocksLeft(mode),
          0,
          reason: '$mode left native blocks alive after $_iterations calls',
        );
      }, testOn: '!windows');
    }

    // These are the error arms, not just the successful allocation loops
    // above. Each child repeatedly drives a native failure and checks that a
    // diagnostic FormatException was actually produced.
    test('failure paths release native allocations', () {
      for (final (mode, what) in const [
        ('parseFailure', 'padded input and failed document'),
        ('decodeFailure', 'padded input'),
        ('ndjsonFailure', 'NDJSON input and partial tape'),
        ('pointerFailure', 'long at/exists/atMany pointer batches'),
        ('selectFailure', 'the per-line document on an atMany failure'),
      ]) {
        expect(
          _liveBlocksLeft(mode),
          0,
          reason:
              '$mode left native blocks alive after $_iterations calls while '
              'checking $what',
        );
      }
    }, testOn: '!windows');

    // Streaming NDJSON must not hold more native memory for a larger file,
    // while the whole-buffer path holds the payload. Same child-process
    // reason as the probes above. This is sequential with them so two
    // `dart run` hook builds do not compete for RAM. The probe reports the
    // most input-copy and tape bytes held at once in each phase. What that
    // number leaves out is listed above the leak probes.
    test(
      'ndjson stream holds chunk-sized native memory, whole-buffer the payload',
      () {
        final result = Process.runSync(Platform.resolvedExecutable, [
          'run',
          'test/ndjson_stream_probe.dart',
        ]);
        expect(result.exitCode, 0, reason: 'probe failed: ${result.stderr}');
        final stdout = result.stdout as String;
        int require(String key) {
          final match = RegExp('$key=([0-9]+)').firstMatch(stdout);
          expect(match, isNotNull, reason: 'probe printed no $key: $stdout');
          return int.parse(match!.group(1)!);
        }

        final chunkBytes = require('CHUNK_BYTES');
        final streamSmallPeak = require('STREAM_SMALL_PEAK_NATIVE_BYTES');
        final streamLargePeak = require('STREAM_LARGE_PEAK_NATIVE_BYTES');
        final wholeLargePeak = require('WHOLE_LARGE_PEAK_NATIVE_BYTES');
        final largeBytes = require('WHOLE_LARGE_FILE_BYTES');
        final smallCount = require('STREAM_SMALL_COUNT');
        final largeCount = require('STREAM_LARGE_COUNT');
        final wholeCount = require('WHOLE_LARGE_COUNT');

        expect(smallCount, 4000);
        expect(largeCount, 20000);
        expect(wholeCount, 20000);

        // A stream batch is one chunk plus the line carried into it, and its
        // input copy and its tape are alive together. Four chunks covers
        // that for any payload size.
        for (final (phase, peak) in [
          ('small', streamSmallPeak),
          ('large', streamLargePeak),
        ]) {
          expect(
            peak,
            lessThan(4 * chunkBytes),
            reason:
                'the $phase stream held ${peak}B of native memory at once, '
                'more than four ${chunkBytes}B chunks. The whole-buffer path held '
                '${wholeLargePeak}B for a ${largeBytes}B payload',
          );
        }
        expect(
          wholeLargePeak,
          greaterThan(largeBytes),
          reason:
              'whole-buffer held only ${wholeLargePeak}B of native memory '
              'for a ${largeBytes}B payload, which it copies in full',
        );
      },
      testOn: '!windows',
    );

    // There is deliberately no test here for the NativeFinalizer reclaiming a
    // document nobody closed. There was one, and it asserted on resident set
    // size after a fixed amount of work — which is a bet on when the garbage
    // collector runs. It passed on a developer machine and failed on Linux CI.
    // A rewrite comparing dropped against retained references was no better:
    // measured back to back, the two arms came out 123 MB and 177 MB, so the
    // margin it claimed was not there.
    //
    // RSS does not fall when native memory is freed — the allocator keeps it —
    // so it cannot answer this question, and the collector makes no promise
    // about timing that a test could hold it to. What is covered instead: the
    // probes above prove the entry points release what they allocate, and the
    // first two tests prove a closed document is unusable and closing twice is
    // safe. The
    // finalizer remains the safety net for callers who forget, attached in the
    // constructor; a red build that depends on GC scheduling would only teach
    // us to ignore red builds.
  });
}
