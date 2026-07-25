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

    test('parse and close in a loop does not leak', () {
      final payload = _bytes(
        '{"items":[${List.generate(200, (i) => '{"id":$i,"n":"x$i"}').join(',')}]}',
      );
      // Warm up so the first allocations are not counted as growth.
      for (var i = 0; i < 200; i++) {
        SimdJsonDocument.parseBytes(payload).close();
      }

      final before = ProcessInfo.currentRss;
      for (var i = 0; i < 3000; i++) {
        SimdJsonDocument.parseBytes(payload)
          ..at('/items/0/n')
          ..close();
      }
      final grownMb = (ProcessInfo.currentRss - before) / (1024 * 1024);

      // Each document holds a parser over a 200-element payload; leaking them
      // would run into the hundreds of megabytes long before 3000 iterations.
      expect(
        grownMb,
        lessThan(50),
        reason: 'grew ${grownMb}MB over 3000 cycles',
      );
    });

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
    // loop above proves the close() path does not leak, and the tests below
    // prove a closed document is unusable and that closing twice is safe. The
    // finalizer remains the safety net for callers who forget, attached in the
    // constructor; a red build that depends on GC scheduling would only teach
    // us to ignore red builds.
  });
}
