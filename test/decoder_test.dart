import 'dart:convert';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

/// Inputs where simdJsonDecode must agree exactly with jsonDecode.
const _agreementCases = <String>[
  'null',
  'true',
  'false',
  '0',
  '-1',
  '42',
  '9223372036854775807',
  '-9223372036854775808',
  '3.14',
  '-0.5',
  '1e10',
  '2.5e-3',
  '""',
  '"hello"',
  r'"esc \" \\ \/ \b \f \n \r \t"',
  r'"unicode çğış snowman ☃"',
  '"UTF-8 direkt: çğışöü 雪 🎿"',
  '[]',
  '[1, 2, 3]',
  '[[[[1]]]]',
  '[1, "two", 3.0, true, null, {"k": []}]',
  '{}',
  '{"a": 1}',
  '{"nested": {"deep": {"deeper": [1, {"x": null}]}}}',
  '{"dup": 1, "other": 2}',
  '  {  "spaced"  :  [ 1 , 2 ]  }  ',
];

const _invalidCases = <String>[
  '',
  '{',
  '[1, 2',
  '{"a": }',
  'tru',
  '"unterminated',
  '{"a": 1,}',
  'NaN',
  '[1] trailing',
];

void main() {
  group('agrees with jsonDecode', () {
    for (final input in _agreementCases) {
      test(input.length > 40 ? '${input.substring(0, 40)}...' : input, () {
        expect(simdJsonDecode(input), jsonDecode(input));
      });
    }
  });

  test('returns the same runtime types as jsonDecode', () {
    final decoded =
        simdJsonDecode('{"i": 1, "d": 1.5, "s": "x", "b": true}')
            as Map<String, dynamic>;
    expect(decoded['i'], isA<int>());
    expect(decoded['d'], isA<double>());
    expect(decoded['s'], isA<String>());
    expect(decoded['b'], isA<bool>());
  });

  test('decodes maps that accept new entries', () {
    final decoded = simdJsonDecode('{"a": 1}') as Map<String, dynamic>;
    decoded['b'] = 2;
    expect(decoded, {'a': 1, 'b': 2});
  });

  test('decodes lists that accept new elements', () {
    final decoded = simdJsonDecode('[1]') as List;
    decoded.add(2);
    expect(decoded, [1, 2]);
  });

  test('uint64 values above int64 come back as doubles', () {
    // dart:convert parses 18446744073709551615 as double too.
    final decoded = simdJsonDecode('[18446744073709551615]') as List;
    expect(decoded.single, isA<double>());
    expect(decoded.single, jsonDecode('[18446744073709551615]')[0]);
  });

  group('numbers simdjson will not represent fall back to jsonDecode', () {
    // simdjson rejects these with NUMBER_ERROR or BIGINT_ERROR; dart:convert
    // accepts them. The package promises jsonDecode's shapes, so it retries
    // with jsonDecode when that is the only reason the parse failed.
    const cases = <String>[
      '18446744073709551616', // 2^64, the smallest integer past uint64
      '99999999999999999999', // 10^20 - 1, the top of the 20-digit window
      '12345678901234567890123',
      '-12345678901234567890123',
      '-9223372036854775809', // one past int64 min
      '1e400', // overflows to Infinity
      '-1e400',
    ];
    for (final literal in cases) {
      test(literal, () {
        final input = '{"v": $literal}';
        expect(simdJsonDecode(input), jsonDecode(input));
      });
    }

    test('NDJSON falls back line by line', () {
      const stream = '{"v": 18446744073709551616}\n{"v": 1}\n{"v": 1e400}\n';
      expect(simdJsonDecodeNdjson(stream), [
        for (final line in stream.split('\n'))
          if (line.trim().isNotEmpty) jsonDecode(line),
      ]);
    });

    test('the fallback does not loosen validation', () {
      // Every one of these is malformed for a reason that is not a number's
      // range, so the retry must not rescue them.
      for (final bad in <String>[
        '{"v": 01}',
        '{"v": 1.}',
        '{"v": +1}',
        '[1,]',
        'tru',
        '',
      ]) {
        expect(
          () => simdJsonDecode(bad),
          throwsFormatException,
          reason: 'input ${jsonEncode(bad)}',
        );
      }
    });

    test('SimdJsonDocument keeps simdjson strictness', () {
      // The lazy reader hands back a handle, not a decoded value, so there is
      // nothing to fall back to and the parse itself is what fails.
      // Documented, not an oversight.
      expect(
        () => SimdJsonDocument.parse('{"v": 18446744073709551616}'),
        throwsFormatException,
      );
    });
  });

  group('rejects invalid JSON with FormatException', () {
    for (final input in _invalidCases) {
      test(input.isEmpty ? '(empty)' : input, () {
        expect(() => simdJsonDecode(input), throwsFormatException);
      });
    }
  });

  test('decodeBytes accepts UTF-8 bytes directly', () {
    final bytes = utf8.encode('{"tr": "çğış", "n": [1, 2.5]}');
    expect(simdJsonDecodeBytes(bytes), jsonDecode(utf8.decode(bytes)));
  });

  test('last duplicate key wins, like jsonDecode', () {
    const input = '{"a": 1, "a": 2}';
    expect(simdJsonDecode(input), jsonDecode(input));
    expect(simdJsonDecode(input), {'a': 2});
  });

  test('arrays beyond the 24-bit size saturation decode completely', () {
    // dom::array::size() saturates at 0xFFFFFF; the shim must count
    // elements itself or the tail is silently dropped.
    const count = 0xFFFFFF + 5;
    final json = StringBuffer('[')
      ..writeAll(Iterable<int>.generate(count, (i) => i & 7), ',')
      ..write(']');
    final decoded = simdJsonDecode(json.toString()) as List;
    expect(decoded.length, count);
    expect(decoded.last, (count - 1) & 7);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('handles a large synthetic document identically', () {
    final doc = {
      'items': [
        for (var i = 0; i < 2000; i++)
          {
            'id': i,
            'name': 'item-$i',
            'price': i * 0.5,
            'tags': ['a', 'b', 'c'],
            'active': i.isEven,
            'meta': i % 3 == 0 ? null : {'rank': i % 7},
          },
      ],
    };
    final encoded = jsonEncode(doc);
    expect(simdJsonDecode(encoded), jsonDecode(encoded));
  });
}
