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
      expect(grownMb, lessThan(50), reason: 'grew ${grownMb}MB over 3000 cycles');
    });

    test('a document that is never closed is reclaimed by the finalizer', () {
      final payload = _bytes(
        '{"items":[${List.generate(200, (i) => '{"id":$i,"n":"x$i"}').join(',')}]}',
      );

      // A real leak grows by the same amount every batch. A finalizer that
      // reclaims lets memory build up until the GC runs and then hands most of
      // it back, so at least one later batch costs almost nothing.
      var previous = ProcessInfo.currentRss;
      final growth = <double>[];
      for (var batch = 0; batch < 6; batch++) {
        for (var i = 0; i < 3000; i++) {
          SimdJsonDocument.parseBytes(payload).at('/items/0/id');
        }
        final now = ProcessInfo.currentRss;
        growth.add((now - previous) / (1024 * 1024));
        previous = now;
      }

      final flattened = growth.skip(1).any((g) => g < 5);
      expect(
        flattened,
        isTrue,
        reason: 'growth per batch was $growth; a leak would stay linear',
      );
    });
  });
}
