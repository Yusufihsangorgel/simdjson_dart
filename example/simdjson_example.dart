import 'dart:convert';
import 'dart:typed_data';

import 'package:simdjson/simdjson.dart';

void main() {
  final bytes = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'meta': {'total': 2},
        'items': [
          {'name': 'first', 'price': 9.5},
          {'name': 'second', 'price': 12.0},
        ],
      }),
    ),
  );

  // Selective access: only the requested values become Dart objects.
  final doc = SimdJsonDocument.parseBytes(bytes);
  try {
    print(doc.at('/meta/total')); // 2
    print(doc.at('/items/1/name')); // second
    print(doc.at('/items/9')); // null (missing)
  } finally {
    doc.close();
  }

  // Full decode, jsonDecode-compatible shapes.
  final decoded = simdJsonDecodeBytes(bytes) as Map<String, dynamic>;
  print((decoded['items'] as List).length); // 2
}
