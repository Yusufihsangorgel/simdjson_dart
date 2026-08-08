import 'dart:convert';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

/// `dart:convert` is the oracle: decoding NDJSON line by line with jsonDecode
/// must give exactly what the single native pass gives.
List<Object?> lineByLine(String ndjson) => [
  for (final line in const LineSplitter().convert(ndjson))
    if (line.trim().isNotEmpty) jsonDecode(line),
];

void main() {
  test('decodes one value per line, in order', () {
    const ndjson = '{"a":1}\n{"a":2}\n{"a":3}\n';
    final rows = simdJsonDecodeNdjson(ndjson);
    expect(rows, lineByLine(ndjson));
    expect(rows.length, 3);
    expect((rows[1] as Map)['a'], 2);
  });

  test('handles mixed document types on separate lines', () {
    const ndjson = '{"k":"v"}\n[1,2,3]\n42\n"text"\ntrue\nnull\n';
    expect(simdJsonDecodeNdjson(ndjson), lineByLine(ndjson));
  });

  test('skips blank lines and tolerates a missing trailing newline', () {
    const ndjson = '{"a":1}\n\n{"a":2}';
    final rows = simdJsonDecodeNdjson(ndjson);
    expect(rows, lineByLine(ndjson));
    expect(rows.length, 2);
  });

  test('a single document works', () {
    expect(simdJsonDecodeNdjson('{"only":true}'), [
      {'only': true},
    ]);
  });

  test('empty input decodes to an empty list', () {
    expect(simdJsonDecodeNdjson(''), isEmpty);
    expect(simdJsonDecodeNdjson('\n\n'), isEmpty);
    expect(simdJsonDecodeNdjsonBytes(Uint8List(0)), isEmpty);
  });

  test('empty input is still empty after a parse that failed', () {
    // One parser is reused per thread, and the truncation check reads
    // bookkeeping that the indexing pass writes. That pass returns early for a
    // zero-byte buffer without writing any of it, so an empty input read
    // whatever the previous parse had left there — and a parse that failed
    // leaves something that reads as "truncated".
    //
    // Three zero-byte inputs, because there are three ways to get one: an empty
    // string, empty bytes, and a buffer holding nothing but a byte-order mark,
    // which is stripped before parsing. The failing setups are varied too, so
    // this does not rest on one of them being the poisoner.
    //
    // It all runs in one synchronous block on purpose: the leak is between two
    // calls on the same thread.
    expect(() => simdJsonDecodeNdjson('{"a":1}\n{"a":'), throwsFormatException);
    expect(simdJsonDecodeNdjson(''), isEmpty);

    expect(
      () => simdJsonDecodeNdjson('{"a":1}\n{"broken":\n'),
      throwsFormatException,
    );
    expect(simdJsonDecodeNdjsonBytes(Uint8List(0)), isEmpty);

    expect(
      () => simdJsonDecodeNdjson('{"a":1}\n{"a":"oops'),
      throwsFormatException,
    );
    expect(simdJsonDecodeNdjson('\u{feff}'), isEmpty);
  });

  test('non-ASCII content round-trips', () {
    const ndjson = '{"city":"İstanbul"}\n{"emoji":"🍰"}\n';
    final rows = simdJsonDecodeNdjson(ndjson);
    expect(rows, lineByLine(ndjson));
    expect((rows[0] as Map)['city'], 'İstanbul');
    expect((rows[1] as Map)['emoji'], '🍰');
  });

  test('an invalid document throws FormatException', () {
    expect(
      () => simdJsonDecodeNdjson('{"a":1}\n{"broken":\n'),
      throwsFormatException,
    );
  });

  test('a truncated last document is an error, not silently dropped', () {
    // A document_stream would otherwise treat the trailing partial document as
    // "completed by a later batch" and drop it, which for a whole-buffer parse
    // means the last record of a truncated log vanishes without a word.
    expect(
      () => simdJsonDecodeNdjson('{"a":1}\n{"a":2}\n{"a":'),
      throwsFormatException,
    );
    // The same input without the truncation keeps every record.
    expect(simdJsonDecodeNdjson('{"a":1}\n{"a":2}\n{"a":3}').length, 3);
  });

  test('a realistic log stream matches dart:convert line by line', () {
    final buffer = StringBuffer();
    for (var i = 0; i < 2000; i++) {
      buffer.writeln(
        jsonEncode({
          'ts': 1750000000 + i,
          'level': i % 7 == 0 ? 'error' : 'info',
          'msg': 'request $i handled',
          'tags': ['http', if (i.isEven) 'cached'],
          'latency_ms': i / 3,
        }),
      );
    }
    final ndjson = buffer.toString();
    final rows = simdJsonDecodeNdjson(ndjson);
    expect(rows.length, 2000);
    expect(rows, lineByLine(ndjson));
  });

  test('the bytes entry point matches the string one', () {
    const ndjson = '{"a":1}\n{"b":[2,3]}\n';
    expect(
      simdJsonDecodeNdjsonBytes(Uint8List.fromList(utf8.encode(ndjson))),
      simdJsonDecodeNdjson(ndjson),
    );
  });
}
