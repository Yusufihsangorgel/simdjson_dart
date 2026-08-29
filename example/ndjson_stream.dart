// Streaming NDJSON: decode a log without holding the file.
//
// simdJsonDecodeNdjsonBytes needs the whole payload as bytes. This example
// uses simdJsonDecodeNdjsonFile, which reads the path in chunks and yields
// one decoded record at a time, and simdJsonDecodeNdjsonStream, fed the
// same bytes cut into 7-byte pieces — small enough that almost every chunk
// ends mid-line, and some land inside a UTF-8 character. Both answers have
// to match a resident decode. Folding each record (not collecting them) is
// the point: toList() would spend the memory this exists to avoid.
//
// Run: dart run example/ndjson_stream.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';

void main() async {
  final workspace = Directory.systemTemp.createTempSync(
    'simdjson_ndjson_stream_',
  );
  final log = File('${workspace.path}/requests.jsonl');
  try {
    final lines = _writeSampleLog(log);
    print('log: $lines lines, ${_size(log.lengthSync())}');
    print('');

    final resident = _LogStats()
      ..addBatch(simdJsonDecodeNdjsonBytes(log.readAsBytesSync()));
    print('resident:    $resident');

    final fromFile = _LogStats();
    await for (final row in simdJsonDecodeNdjsonFile(log.path)) {
      fromFile.add(row);
    }
    print(
      'file stream: $fromFile — same as resident: ${_same(fromFile, resident)}',
    );

    final fromChunks = _LogStats();
    await for (final row in simdJsonDecodeNdjsonStream(
      _chunksOf(log.readAsBytesSync(), 7),
    )) {
      fromChunks.add(row);
    }
    print(
      '7-byte chunks: $fromChunks — same as resident: ${_same(fromChunks, resident)}',
    );
    print('');

    // The same short document, split once inside a string and once inside
    // a multi-byte character. Both have to match the whole-buffer decode.
    const line = '{"city":"İstanbul","emoji":"🍰","msg":"hello world"}';
    final bytes = Uint8List.fromList(utf8.encode('$line\n'));
    final whole = simdJsonDecodeNdjsonBytes(bytes);
    final helloAt = _indexOf(bytes, utf8.encode('hello'));
    final iDotAt = _indexOf(bytes, [0xC4, 0xB0]);
    print(
      'split inside "hello": same as whole buffer: '
      '${_eq(await _split(bytes, helloAt + 3), whole)}',
    );
    print(
      'split inside İ:       same as whole buffer: '
      '${_eq(await _split(bytes, iDotAt + 1), whole)}',
    );

    try {
      await simdJsonDecodeNdjsonStream(
        Stream.fromIterable([
          Uint8List.sublistView(bytes, 0, bytes.length - 8),
        ]),
      ).drain();
      print('truncated: decoded — it should have thrown');
    } on FormatException catch (e) {
      print('truncated: $e');
    }
  } finally {
    workspace.deleteSync(recursive: true);
  }
}

class _LogStats {
  int rows = 0;
  int errors = 0;

  void add(Object? row) {
    final record = row as Map<String, dynamic>;
    rows++;
    if (record['level'] == 'error') errors++;
  }

  void addBatch(List<Object?> batch) {
    for (final row in batch) {
      add(row);
    }
  }

  @override
  String toString() => '$rows rows, $errors errors';
}

int _writeSampleLog(File file) {
  final random = Random(7);
  const total = 8000;
  final pending = StringBuffer();
  for (var i = 0; i < total; i++) {
    pending.writeln(
      jsonEncode({
        'i': i,
        'level': random.nextInt(50) == 0 ? 'error' : 'info',
        'path': i.isEven ? '/api/検索' : '/api/orders',
        'msg': 'hello world',
      }),
    );
    if (pending.length > 64 * 1024) {
      file.writeAsStringSync(pending.toString(), mode: FileMode.append);
      pending.clear();
    }
  }
  if (pending.isNotEmpty) {
    file.writeAsStringSync(pending.toString(), mode: FileMode.append);
  }
  return total;
}

Stream<Uint8List> _chunksOf(Uint8List bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    final end = min(i + size, bytes.length);
    yield Uint8List.fromList(Uint8List.sublistView(bytes, i, end));
  }
}

Future<List<Object?>> _split(Uint8List bytes, int offset) =>
    simdJsonDecodeNdjsonStream(
      Stream.fromIterable([
        Uint8List.sublistView(bytes, 0, offset),
        Uint8List.sublistView(bytes, offset),
      ]),
    ).toList();

int _indexOf(Uint8List haystack, List<int> needle) {
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

bool _same(_LogStats a, _LogStats b) =>
    a.rows == b.rows && a.errors == b.errors;

bool _eq(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_deepEq(a[i], b[i])) return false;
  }
  return true;
}

bool _deepEq(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEq(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
