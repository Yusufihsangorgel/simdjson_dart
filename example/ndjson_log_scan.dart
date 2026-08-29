// The other job simdjson_dart does: reading a newline-delimited log.
//
// A request log is the shape almost every backend ships: one JSON document
// per line, in a `.jsonl` or `.ndjson` file. The usual way to read one is a
// `jsonDecode` per line; `simdJsonDecodeNdjsonBytes` hands the whole buffer to
// simdjson once instead. This example answers a real question about such a log
// (how many requests failed, and which endpoint was slowest) two ways: with
// the file resident in memory, and with `simdJsonDecodeNdjsonFile`, which
// reads in chunks and yields one record at a time. The whole-buffer path has
// one trap in it, and that trap is most of the point.
//
// Run: dart run example/ndjson_log_scan.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';

/// The NDJSON delimiter.
///
/// Splitting raw UTF-8 bytes on this is safe without decoding them first:
/// every byte of a multi-byte UTF-8 sequence has its high bit set, so 0x0A
/// can only ever be a real newline and never part of a character. The sample
/// log below carries non-ASCII paths on purpose, so the run exercises that.
const _newline = 0x0A;

void main() async {
  // Directory.systemTemp, not the repo: an example that writes into the
  // project it ships with is an example that dirties someone's checkout.
  final workspace = Directory.systemTemp.createTempSync('simdjson_ndjson_');
  final log = File('${workspace.path}/requests.jsonl');
  try {
    final lines = _writeSampleLog(log);
    print('log: $lines lines, ${_size(log.lengthSync())}');
    print('');

    // ---------------------------------------------------------------------
    // Way 1: the whole file, one native pass. Reach for this first.
    //
    // The margin over decoding line by line comes from making a single trip
    // into native code instead of one per record. The package README measures
    // it at 10.4 ms against 17.8 ms for a `jsonDecode` per line on a 2.11 MB
    // log of 20,000 documents, about 1.7x. Both paths materialize every
    // record, so this is the moderate full-decode margin, not the 5-14x that
    // selective access with SimdJsonDocument gets. Under about 100 KB,
    // `dart:convert` wins outright; the FFI boundary is not free.
    final bytes = log.readAsBytesSync();
    final resident = _LogStats()..addBatch(simdJsonDecodeNdjsonBytes(bytes));
    print('resident: $resident');
    print('          peak buffer ${_size(bytes.length)} — the whole file');
    print('');

    // ---------------------------------------------------------------------
    // Way 2: bounded memory. Reach for this when the log is bigger than you
    // are willing to hold: a day of production traffic rather than 20,000
    // lines. The file is read in chunks; a partial line rides to the next
    // one. The answer must come out identical; if it does not, the stream
    // is wrong.
    final streamed = _LogStats();
    await for (final row in simdJsonDecodeNdjsonFile(log.path)) {
      streamed.add(row);
    }
    final sameAnswer =
        streamed.rows == resident.rows &&
        streamed.errors == resident.errors &&
        streamed.anonymous == resident.anonymous &&
        streamed.slowestMs == resident.slowestMs &&
        streamed.slowestPath == resident.slowestPath;
    print('streamed: $streamed');
    print('          same answer as the resident pass: $sameAnswer');
    print('');

    // ---------------------------------------------------------------------
    // The trap, on the whole-buffer path. Hand simdJsonDecodeNdjsonBytes a
    // chunk that stops mid-line and it rejects the entire batch rather than
    // the one broken record. simdJsonDecodeNdjsonFile does the carry for
    // you; this is what you hit if you split the bytes yourself and forget.
    //
    // That is deliberate on the package's side. simdjson's document stream
    // normally treats a trailing fragment as something a later batch will
    // finish, which for a whole-buffer parse means the last record of a
    // cut-off log disappears without a word. An exception you have to handle
    // beats a count that is quietly short, so this throws instead.
    //
    // The reason this trap bites in production and not in testing: whether a
    // chunk boundary lands mid-line depends on the data, so a 64 KB chunk
    // over a fixture file can get lucky and the same code over real traffic
    // will not.
    final choppedMidLine = Uint8List.sublistView(bytes, 0, _insideLine4(bytes));
    try {
      simdJsonDecodeNdjsonBytes(choppedMidLine);
      print('trap: decoded a mid-line chunk — it should have thrown');
    } on FormatException catch (e) {
      print('trap: a mid-line chunk throws — ${e.message}');
    }

    // The same guarantee is what makes a truncated file an error rather than
    // a quietly short answer, which is the failure the exception exists to
    // prevent.
    try {
      simdJsonDecodeNdjsonBytes(_truncate(bytes));
      print('trap: decoded a truncated log — it should have thrown');
    } on FormatException catch (e) {
      print('trap: a truncated log throws too — ${e.message}');
    }
  } finally {
    workspace.deleteSync(recursive: true);
  }
}

/// What the caller actually wanted out of the log.
class _LogStats {
  int rows = 0;
  int errors = 0;
  int anonymous = 0;
  double slowestMs = -1;
  String slowestPath = '';

  /// Folds one record and lets it go.
  ///
  /// Records are deliberately not collected. Keeping every decoded row
  /// would move the memory from bytes into Dart objects and give back
  /// everything the streamed read bought. Objects cost more than the bytes
  /// they came from, not less.
  void add(Object? row) {
    final record = row as Map<String, dynamic>;
    rows++;
    if (record['level'] == 'error') errors++;
    // An absent field reads as null, the same as `jsonDecode` gives;
    // unauthenticated requests carry no `user` key at all.
    if (record['user'] == null) anonymous++;
    final latency = (record['latency_ms'] as num).toDouble();
    if (latency > slowestMs) {
      slowestMs = latency;
      slowestPath = record['path'] as String;
    }
  }

  void addBatch(List<Object?> batch) {
    for (final row in batch) {
      add(row);
    }
  }

  @override
  String toString() =>
      '$rows rows, $errors errors, $anonymous anonymous, '
      'slowest ${slowestMs.toStringAsFixed(1)} ms on $slowestPath';
}

/// Writes a sample request log and returns the number of lines.
///
/// Seeded, so the numbers this example prints are the same on every machine.
/// Written in batches for the same reason the reader above reads in chunks.
int _writeSampleLog(File file) {
  final random = Random(7);
  const paths = [
    '/api/orders',
    '/api/orders/{id}',
    '/api/users',
    '/api/search',
    '/api/kargo/özet', // Non-ASCII on purpose: multi-byte UTF-8 in the data.
    '/api/検索',
  ];
  const total = 20000;
  final pending = StringBuffer();
  for (var i = 0; i < total; i++) {
    final failed = random.nextInt(50) == 0;
    // Failures are the slow ones, so "slowest endpoint" has a real answer.
    final latency = failed
        ? 400 + random.nextDouble() * 600
        : random.nextDouble() * 120;
    pending.writeln(
      jsonEncode({
        'ts': 1750000000 + i,
        'level': failed ? 'error' : 'info',
        'method': random.nextInt(4) == 0 ? 'POST' : 'GET',
        'path': paths[random.nextInt(paths.length)],
        'status': failed ? 500 : 200,
        'latency_ms': double.parse(latency.toStringAsFixed(2)),
        if (random.nextInt(3) != 0) 'user': 'u-${random.nextInt(9000) + 1000}',
      }),
    );
    if (pending.length > 256 * 1024) {
      file.writeAsStringSync(pending.toString(), mode: FileMode.append);
      pending.clear();
    }
  }
  if (pending.isNotEmpty) {
    file.writeAsStringSync(pending.toString(), mode: FileMode.append);
  }
  return total;
}

/// A byte offset that certainly sits inside a record rather than after a
/// newline: ten bytes past the third delimiter.
int _insideLine4(Uint8List bytes) {
  var seen = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == _newline && ++seen == 3) return i + 10;
  }
  throw StateError('the sample log should have more than three lines');
}

/// [bytes] with the final record cut in half, the shape a log has when the
/// process writing it was killed.
Uint8List _truncate(Uint8List bytes) {
  // The log ends with a delimiter, so the newline that opens the final record
  // is the last one before that.
  final trailing = _lastNewlineIn(bytes);
  final opensLastRecord = _lastNewlineIn(
    Uint8List.sublistView(bytes, 0, trailing),
  );
  return Uint8List.sublistView(bytes, 0, opensLastRecord + 12);
}

int _lastNewlineIn(Uint8List bytes) {
  for (var i = bytes.length - 1; i >= 0; i--) {
    if (bytes[i] == _newline) return i;
  }
  return -1;
}

String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
