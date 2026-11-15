// Runs inside the app the compat workflow generates and not in this package.
// The flutter_test and integration_test imports resolve in that app.
// tool/ci/prepare_app.dart copies it to the app's integration_test directory.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simdjson_dart/simdjson_dart.dart';

const _json = '''
{
  "meta": {"total": 3, "page": 1, "ratio": 1.25, "big": -2.5e3},
  "items": [
    {"id": 0, "name": "alpha", "inStock": true},
    {"id": 1, "name": "caf\\u00e9 \\ud83d\\ude00", "inStock": false},
    {"id": 2, "name": null, "inStock": true}
  ]
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('decodes a document with the native parser', () {
    final decoded = simdJsonDecode(_json);

    expect(decoded, jsonDecode(_json));
    final meta = (decoded as Map<String, Object?>)['meta'] as Map;
    expect(meta['total'], 3);
    expect(meta['ratio'], 1.25);
    expect(meta['big'], -2500.0);
  });

  test('reads single fields without decoding the rest', () {
    final doc = SimdJsonDocument.parse(_json);
    addTearDown(doc.close);

    expect(doc.at('/meta/total'), 3);
    expect(doc.at('/items/0/name'), 'alpha');
    expect(doc.at('/items/1/name'), 'café \u{1F600}');
    expect(doc.at('/items/2/name'), isNull);
    expect(doc.at('/items/2/inStock'), isTrue);
    expect(doc.at('/meta/cursor'), isNull);
    expect(doc.exists('/meta/ratio'), isTrue);
    expect(doc.exists('/meta/cursor'), isFalse);
  });

  test('decodes NDJSON records', () {
    final records = simdJsonDecodeNdjson('{"n": 1}\n{"n": 2}\n{"n": 3}\n');

    expect(records, [
      {'n': 1},
      {'n': 2},
      {'n': 3},
    ]);
  });

  test('rejects invalid JSON with a FormatException from the parser', () {
    // The message comes from the native parser.
    expect(
      () => SimdJsonDocument.parse('{"a": }'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          startsWith('TAPE_ERROR'),
        ),
      ),
    );
  });
}
