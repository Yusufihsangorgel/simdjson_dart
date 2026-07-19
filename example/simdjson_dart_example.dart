// The scenario simdjson_dart is built for: pulling a few fields out of a large
// JSON payload without materializing the whole thing.
//
// Run: dart run example/simdjson_dart_example.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';

void main() {
  // A paginated API response with 50,000 items: a few megabytes of JSON. You
  // need the page header and the first record, not the other 49,999.
  final payload = <String, Object?>{
    'meta': {'total': 50000, 'page': 1, 'generatedAt': '2026-07-20T00:00:00Z'},
    'items': [
      for (var i = 0; i < 50000; i++)
        {'id': i, 'name': 'item-$i', 'price': i * 1.5, 'inStock': i.isEven},
    ],
  };
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  print('payload: ${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB');

  // Selective access: parse once, then read only the fields you ask for. The
  // 49,999 records you never touch never become Dart maps. Reading fields near
  // the top of the document (the header, the first record) is where this wins,
  // and it is measured at 5-14x over a full decode in the README benchmark.
  final doc = SimdJsonDocument.parseBytes(bytes);
  try {
    print('total:      ${doc.at('/meta/total')}'); // 50000
    print('page:       ${doc.at('/meta/page')}'); // 1
    print('first id:   ${doc.at('/items/0/id')}'); // 0
    print('first name: ${doc.at('/items/0/name')}'); // item-0
    print('missing:    ${doc.at('/meta/cursor')}'); // null
  } finally {
    // close() frees the native document now instead of waiting for the
    // finalizer. It matters here because the document is large.
    doc.close();
  }

  // `at` walks arrays from the front, so a deep index like `/items/49999` is not
  // where it wins; reach for a full decode when you need most of the document.
  // That path is jsonDecode-compatible:
  final decoded = simdJsonDecodeBytes(bytes) as Map<String, Object?>;
  print('full-decode item count: ${(decoded['items'] as List).length}'); // 50000

  // Invalid JSON fails loudly, not silently: parse throws a FormatException so
  // bad input never turns into a wrong value.
  try {
    SimdJsonDocument.parseBytes(Uint8List.fromList(utf8.encode('{"a": }')));
  } on FormatException catch (e) {
    print('rejected bad input: ${e.message.split('.').first}');
  }
}
