import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

Stream<Uint8List> _chunksOf(List<int> bytes, int size) async* {
  if (bytes.isEmpty) return;
  for (var i = 0; i < bytes.length; i += size) {
    final end = i + size > bytes.length ? bytes.length : i + size;
    yield Uint8List.fromList(bytes.sublist(i, end));
  }
}

Stream<Uint8List> _splitAt(List<int> bytes, int offset) => Stream.fromIterable([
  Uint8List.fromList(bytes.sublist(0, offset)),
  Uint8List.fromList(bytes.sublist(offset)),
]);

Future<List<Object?>> _decodeChunks(List<int> bytes, int size) =>
    simdJsonDecodeNdjsonStream(_chunksOf(bytes, size)).toList();

Future<List<Object?>> _decodeSplit(List<int> bytes, int offset) =>
    simdJsonDecodeNdjsonStream(_splitAt(bytes, offset)).toList();

void main() {
  // A short document that contains a string, a 2-byte UTF-8 character (İ)
  // and a 4-byte one (🍰), so a split at every offset lands inside all three.
  const awkward =
      '{"city":"İstanbul","emoji":"🍰","msg":"hello world"}\n{"n":2}\n';
  final awkwardBytes = _bytes(awkward);
  final awkwardExpected = simdJsonDecodeNdjson(awkward);

  group('chunk boundaries', () {
    test('every two-way split matches the whole-buffer decode', () async {
      for (var offset = 1; offset < awkwardBytes.length; offset++) {
        expect(
          await _decodeSplit(awkwardBytes, offset),
          awkwardExpected,
          reason: 'split at byte $offset of ${awkwardBytes.length}',
        );
      }
    });

    test(
      'chunk sizes that bisect lines match the whole-buffer decode',
      () async {
        final sizes = <int>[
          1,
          2,
          3,
          7,
          8,
          15,
          16,
          17,
          64,
          awkwardBytes.length - 1,
          awkwardBytes.length,
          awkwardBytes.length + 10,
        ];
        for (final size in sizes) {
          expect(
            await _decodeChunks(awkwardBytes, size),
            awkwardExpected,
            reason: 'chunkSize $size',
          );
        }
      },
    );

    test('a split inside a string literal matches', () async {
      final offset = _indexOfBytes(awkwardBytes, utf8.encode('hello')) + 3;
      expect(utf8.decode([awkwardBytes[offset - 1]]), 'l');
      expect(utf8.decode([awkwardBytes[offset]]), 'l');
      expect(await _decodeSplit(awkwardBytes, offset), awkwardExpected);
    });

    test('a split inside a 2-byte UTF-8 character matches', () async {
      // İ is U+0130, UTF-8 C4 B0.
      final offset = _indexOfBytes(awkwardBytes, [0xC4, 0xB0]) + 1;
      expect(awkwardBytes[offset - 1], 0xC4);
      expect(awkwardBytes[offset], 0xB0);
      expect(await _decodeSplit(awkwardBytes, offset), awkwardExpected);
    });

    test('a split inside a 4-byte UTF-8 character matches', () async {
      // 🍰 is U+1F370, UTF-8 F0 9F 8D B0.
      final start = _indexOfBytes(awkwardBytes, [0xF0, 0x9F, 0x8D, 0xB0]);
      for (var extra = 1; extra <= 3; extra++) {
        expect(
          await _decodeSplit(awkwardBytes, start + extra),
          awkwardExpected,
          reason: 'split $extra bytes into 🍰',
        );
      }
    });

    test('empty chunks between real ones are ignored', () async {
      final bytes = _bytes('{"a":1}\n{"a":2}\n');
      final mixed = Stream<List<int>>.fromIterable([
        bytes.sublist(0, 4),
        <int>[],
        bytes.sublist(4, 10),
        Uint8List(0),
        bytes.sublist(10),
      ]);
      expect(await simdJsonDecodeNdjsonStream(mixed).toList(), [
        {'a': 1},
        {'a': 2},
      ]);
    });

    test('plain List<int> chunks match Uint8List chunks', () async {
      final bytes = _bytes('{"a":1}\n{"b":[2,3]}\n');
      final asLists = Stream<List<int>>.fromIterable([
        bytes.sublist(0, 5).toList(),
        bytes.sublist(5).toList(),
      ]);
      expect(
        await simdJsonDecodeNdjsonStream(asLists).toList(),
        simdJsonDecodeNdjsonBytes(bytes),
      );
    });

    test('a realistic log matches in 1-byte and 7-byte chunks', () async {
      final buffer = StringBuffer();
      for (var i = 0; i < 200; i++) {
        buffer.writeln(
          jsonEncode({
            'i': i,
            'city': 'İstanbul',
            'emoji': '🍰',
            'msg': 'request $i handled',
          }),
        );
      }
      final ndjson = buffer.toString();
      final bytes = _bytes(ndjson);
      final expected = simdJsonDecodeNdjson(ndjson);
      expect(await _decodeChunks(bytes, 1), expected);
      expect(await _decodeChunks(bytes, 7), expected);
    });
  });

  group('agrees with the whole-buffer path', () {
    test('mixed document types, blank lines, no trailing newline', () async {
      const ndjson = '{"k":"v"}\n\n[1,2,3]\n42\n"text"\ntrue\nnull';
      expect(
        await _decodeChunks(_bytes(ndjson), 3),
        simdJsonDecodeNdjson(ndjson),
      );
    });

    test('CRLF line endings', () async {
      const ndjson = '{"a":1}\r\n{"a":2}\r\n';
      expect(
        await _decodeChunks(_bytes(ndjson), 1),
        simdJsonDecodeNdjson(ndjson),
      );
    });

    test('a leading BOM survives 1-byte chunks', () async {
      const ndjson = '\u{feff}{"a":1}\n{"a":2}\n';
      expect(
        await _decodeChunks(_bytes(ndjson), 1),
        simdJsonDecodeNdjson(ndjson),
      );
    });

    test('JSON null is yielded as null', () async {
      expect(await _decodeChunks(_bytes('null\n{"a":1}\n'), 2), [
        null,
        {'a': 1},
      ]);
    });

    test('empty input yields nothing', () async {
      expect(
        await simdJsonDecodeNdjsonStream(const Stream.empty()).toList(),
        isEmpty,
      );
      expect(await _decodeChunks(Uint8List(0), 64), isEmpty);
      expect(await _decodeChunks(_bytes('\n\n'), 1), isEmpty);
    });

    test('number-range failures fall back to jsonDecode', () async {
      const stream = '{"v": 18446744073709551616}\n{"v": 1}\n{"v": 1e400}\n';
      expect(
        await _decodeChunks(_bytes(stream), 5),
        simdJsonDecodeNdjson(stream),
      );
    });
  });

  group('malformed input', () {
    test('a truncated last document throws FormatException', () async {
      const truncated = '{"a":1}\n{"a":2}\n{"a":';
      await expectLater(
        simdJsonDecodeNdjsonStream(Stream.fromIterable([_bytes(truncated)])),
        emitsInOrder([
          {'a': 1},
          {'a': 2},
          emitsError(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('incomplete document'),
            ),
          ),
        ]),
      );
    });

    test('a truncation split across chunks still throws', () async {
      final bytes = _bytes('{"a":1}\n{"a":');
      await expectLater(
        simdJsonDecodeNdjsonStream(_chunksOf(bytes, 3)),
        emitsInOrder([
          {'a': 1},
          emitsError(isA<FormatException>()),
        ]),
      );
    });

    test('an invalid complete line throws FormatException', () async {
      await expectLater(
        simdJsonDecodeNdjsonStream(
          Stream.fromIterable([_bytes('{"a":1}\n{"broken":\n')]),
        ),
        emitsError(isA<FormatException>()),
      );
    });

    test(
      'records from earlier chunks are yielded before a later error',
      () async {
        // Two chunks so the first document is a finished batch before the
        // broken line is seen. The whole-buffer path is all-or-nothing.
        await expectLater(
          simdJsonDecodeNdjsonStream(
            Stream.fromIterable([_bytes('{"a":1}\n'), _bytes('{"broken":\n')]),
          ),
          emitsInOrder([
            {'a': 1},
            emitsError(isA<FormatException>()),
          ]),
        );
      },
    );
  });

  group('simdJsonDecodeNdjsonFile', () {
    late Directory dir;

    setUp(
      () => dir = Directory.systemTemp.createTempSync('simdjson_ndjson_file'),
    );
    tearDown(() => dir.deleteSync(recursive: true));

    File write(String name, String contents) =>
        File('${dir.path}/$name')..writeAsStringSync(contents);

    test('reads a file without the caller holding the bytes', () async {
      final file = write('rows.jsonl', '{"a":1}\n{"a":2}\n{"a":3}\n');
      expect(await simdJsonDecodeNdjsonFile(file.path).toList(), [
        {'a': 1},
        {'a': 2},
        {'a': 3},
      ]);
    });

    test('matches the whole-buffer decode at tiny chunk sizes', () async {
      final ndjson =
          '{"city":"İstanbul","emoji":"🍰"}\n{"msg":"hello"}\n{"n":3}\n';
      final file = write('utf8.jsonl', ndjson);
      final expected = simdJsonDecodeNdjson(ndjson);
      expect(
        await simdJsonDecodeNdjsonFile(file.path, chunkSize: 1).toList(),
        expected,
      );
      expect(
        await simdJsonDecodeNdjsonFile(file.path, chunkSize: 7).toList(),
        expected,
      );
    });

    test('a missing file is IO_ERROR, a malformed one is not', () async {
      await expectLater(
        simdJsonDecodeNdjsonFile('${dir.path}/absent.jsonl').toList(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('IO_ERROR'),
          ),
        ),
      );
      final bad = write('bad.jsonl', '{"a":1}\n{"a":');
      await expectLater(
        simdJsonDecodeNdjsonFile(bad.path).toList(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            isNot(contains('IO_ERROR')),
          ),
        ),
      );
    });

    test('handles a non-ASCII path', () async {
      final file = write('ölçüm-测试.jsonl', '{"ok":true}\n');
      expect(await simdJsonDecodeNdjsonFile(file.path).toList(), [
        {'ok': true},
      ]);
    });

    test('an empty file yields nothing', () async {
      final empty = write('empty.jsonl', '');
      expect(await simdJsonDecodeNdjsonFile(empty.path).toList(), isEmpty);
    });

    test('chunkSize must be at least 1', () {
      expect(
        () => simdJsonDecodeNdjsonFile('${dir.path}/x', chunkSize: 0),
        throwsArgumentError,
      );
    });
  });
}

int _indexOfBytes(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  throw StateError('needle not found');
}
