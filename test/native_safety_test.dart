import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

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

    // Every native buffer these entry points allocate has to come back. The
    // measurement runs in a child process (test/leak_probe.dart) because
    // `dart test` runs suites concurrently in one process, and the resident set
    // then reflects whatever the other suites are doing - over 500MB of
    // unrelated growth when measured from inside a test here.
    //
    // Each bound is derived from the payload rather than picked as a round
    // number: it is the cost of losing the single smallest free on that path,
    // divided by four. Removing any one free in decoder.dart or document.dart
    // fails the matching case below.
    for (final probe in const [
      ('parseBytes', 'padded input and the tape behind at()', 65.5),
      ('decodeBytes', 'the tape and the native copy of the input', 65.5),
      ('ndjson', 'the tape and the native copy of the input', 92.1),
      ('pointer', 'the native copy of a long JSON pointer', 46.9),
    ]) {
      final (mode, what, smallestLeakMb) = probe;

      test('$mode releases $what', () {
        const iterations = 1500;
        final result = Process.runSync(Platform.resolvedExecutable, [
          'run',
          'test/leak_probe.dart',
          mode,
          '$iterations',
        ]);

        expect(
          result.exitCode,
          0,
          reason: 'leak_probe failed: ${result.stderr}',
        );
        final reported = RegExp(
          r'RSS_DELTA_MB=(-?[0-9.]+)',
        ).firstMatch(result.stdout as String);
        expect(
          reported,
          isNotNull,
          reason: 'leak_probe printed no measurement: ${result.stdout}',
        );
        final grownMb = double.parse(reported!.group(1)!);

        expect(
          grownMb,
          lessThan(smallestLeakMb / 4),
          reason:
              'grew ${grownMb}MB over $iterations iterations; losing the '
              'smallest native buffer on this path would cost '
              '${smallestLeakMb}MB',
        );
      });
    }

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
