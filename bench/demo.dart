// A focused demo for the write-up: read three fields out of a ~9 MB JSON
// response, once with dart:convert and once with simdjson_dart.
// Run with: dart run bench/demo.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';

String _buildApiResponse() {
  final items = <Map<String, dynamic>>[];
  for (var i = 0; i < 85000; i++) {
    items.add({
      'id': i,
      'name': 'item-$i',
      'price': (i % 1000) + 0.5,
      'tags': const ['new', 'sale', 'featured'],
      'nested': {'rank': i % 97, 'active': i.isEven},
    });
  }
  return jsonEncode({
    'meta': {'total': items.length},
    'items': items,
  });
}

int _medianMs(void Function() body, {int warmup = 5, int runs = 25}) {
  for (var i = 0; i < warmup; i++) {
    body();
  }
  final micros = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    micros.add(sw.elapsedMicroseconds);
  }
  micros.sort();
  return (micros[micros.length ~/ 2] / 1000).round();
}

void main() {
  // Clear the "Running build hooks..." status line the Dart tool prints.
  stdout.write('\r\x1B[2KBuilding a JSON API response...  ');
  final json = _buildApiResponse();
  final bytes = Uint8List.fromList(utf8.encode(json));
  stdout.writeln('${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB');
  stdout.writeln('');
  stdout.writeln('Reading 3 fields out of it:');
  stdout.writeln('');

  final withConvert = _medianMs(() {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final items = root['items'] as List;
    (items[0] as Map)['name'];
    (items[20000] as Map)['price'];
    ((items[39999] as Map)['nested'] as Map)['rank'];
  });

  final withSimd = _medianMs(() {
    final doc = SimdJsonDocument.parseBytes(bytes);
    try {
      doc.at('/items/0/name');
      doc.at('/items/20000/price');
      doc.at('/items/39999/nested/rank');
    } finally {
      doc.close();
    }
  });

  String row(String label, int ms, String note) =>
      '  ${label.padRight(22)}${'$ms ms'.padLeft(6)}   $note';

  stdout.writeln(row('jsonDecode + index', withConvert, 'builds the whole tree'));
  stdout.writeln(row('SimdJsonDocument.at', withSimd, 'reads only the 3 fields'));
  stdout.writeln('');
  stdout.writeln('  ${(withConvert / withSimd).toStringAsFixed(1)}x faster');
}
