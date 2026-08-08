// The other job simdjson_dart does: reading a newline-delimited log.
//
// A request log is the shape almost every backend ships: one JSON document
// per line, in a `.jsonl` or `.ndjson` file. The usual way to read one is a
// `jsonDecode` per line; `simdJsonDecodeNdjsonBytes` hands the whole buffer to
// simdjson once instead. This example answers a real question about such a log
// (how many requests failed, and which endpoint was slowest) two ways: with
// the file resident in memory, and in bounded memory for a file too big for
// that. The second way has one trap in it, and that trap is most of the point.
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

void main() {
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
    // lines. The answer must come out identical; if it does not, the chunking
    // is wrong.
    const chunkSize = 64 * 1024;
    final streamed = _LogStats();
    final peak = _scanInChunks(log.path, chunkSize, streamed.addBatch);
    final sameAnswer =
        streamed.rows == resident.rows &&
        streamed.errors == resident.errors &&
        streamed.anonymous == resident.anonymous &&
        streamed.slowestMs == resident.slowestMs &&
        streamed.slowestPath == resident.slowestPath;
    print('chunked:  $streamed');
    print(
      '          peak buffer ${_size(peak)} — one chunk plus a partial line, '
      '${(bytes.length / peak).toStringAsFixed(0)}x less than the file',
    );
    print('          same answer as the resident pass: $sameAnswer');
    print('');

    // ---------------------------------------------------------------------
    // The trap. Hand the decoder a chunk that stops mid-line and it rejects
    // the entire batch rather than the one broken record.
    //
    // That is deliberate on the package's side. simdjson's document stream
    // normally treats a trailing fragment as something a later batch will
    // finish, which for a whole-buffer parse means the last record of a
    // cut-off log disappears without a word. An exception you have to handle
    // beats a count that is quietly short, so this throws instead, and that
    // is why the loop above carries the fragment forward rather than handing
    // it over.
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

    // The same guarantee is what makes the end of the loop matter. Dropping
    // the leftover fragment at EOF instead of flushing it would turn a
    // truncated log into a quietly short answer, which is the failure the
    // exception above exists to prevent.
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

/// Folds every whole line of the file at [path] into [onBatch], holding no
/// more than [chunkSize] bytes plus one partial line at a time.
///
/// Returns the largest buffer it had to hold, which is the bound the caller
/// actually bought. Note what that bound is made of: a single line longer
/// than [chunkSize] still has to fit, because a fragment cannot be decoded.
int _scanInChunks(
  String path,
  int chunkSize,
  void Function(List<Object?> batch) onBatch,
) {
  final handle = File(path).openSync();
  var carry = Uint8List(0);
  var peak = 0;
  try {
    while (true) {
      final chunk = handle.readSync(chunkSize);
      if (chunk.isEmpty) break; // EOF.

      // A chunk boundary is a byte offset, not a line boundary, so glue last
      // round's leftover fragment onto the front of this one.
      final buffer = carry.isEmpty ? chunk : _join(carry, chunk);
      peak = max(peak, buffer.length);

      final lastNewline = _lastNewlineIn(buffer);
      if (lastNewline < 0) {
        // Not one complete line yet: this record is longer than a chunk.
        // Keep reading rather than handing over something unparseable.
        carry = buffer;
        continue;
      }

      // Copy the tail instead of keeping a view of `buffer`. A view would
      // pin the entire chunk alive to hold a few dozen bytes, which is the
      // opposite of why we are reading in chunks.
      carry = Uint8List.fromList(
        Uint8List.sublistView(buffer, lastNewline + 1),
      );
      onBatch(
        simdJsonDecodeNdjsonBytes(
          Uint8List.sublistView(buffer, 0, lastNewline + 1),
        ),
      );
    }

    // Flush. A log that does not end in a newline still has a real record
    // sitting here, and dropping it is exactly the silent data loss this
    // whole dance is about. If the file was cut off mid-document instead,
    // this is where it throws, which is the outcome you want.
    if (carry.isNotEmpty) onBatch(simdJsonDecodeNdjsonBytes(carry));
  } finally {
    handle.closeSync();
  }
  return peak;
}

/// What the caller actually wanted out of the log.
class _LogStats {
  int rows = 0;
  int errors = 0;
  int anonymous = 0;
  double slowestMs = -1;
  String slowestPath = '';

  /// Folds one batch and lets it go.
  ///
  /// The batches are deliberately not collected. Keeping every decoded row
  /// would move the memory from bytes into Dart objects and give back
  /// everything the chunked read bought. Objects cost more than the bytes
  /// they came from, not less.
  void addBatch(List<Object?> batch) {
    for (final row in batch) {
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

Uint8List _join(Uint8List head, Uint8List tail) =>
    Uint8List(head.length + tail.length)
      ..setRange(0, head.length, head)
      ..setRange(head.length, head.length + tail.length, tail);

String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
