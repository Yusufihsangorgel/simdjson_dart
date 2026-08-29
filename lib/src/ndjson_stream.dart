import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'decoder.dart';

/// The NDJSON record delimiter. Splitting raw UTF-8 on this byte is safe:
/// every byte of a multi-byte sequence has its high bit set, so 0x0A is
/// never part of a character.
const _newline = 0x0A;

/// Default read size for [simdJsonDecodeNdjsonFile]. Memory tracks this
/// plus the longest line, not the file.
const _defaultChunkSize = 64 * 1024;

/// Decodes newline-delimited JSON as it arrives, holding the current chunk
/// and any unfinished line rather than the whole payload.
///
/// [simdJsonDecodeNdjsonBytes] needs the file resident. The reason to use
/// NDJSON is that the file is large, so that requirement fights the format.
/// This reads UTF-8 bytes from [source], yields one decoded value per
/// document with the same shapes `jsonDecode` returns, and keeps the bytes
/// after the last newline to glue onto the next chunk.
///
/// A chunk that ends mid-line, inside a string, or in the middle of a
/// multi-byte UTF-8 character is not an error: those bytes ride forward.
/// Handing this a single chunk that *is* the whole file is the whole-buffer
/// path; the bound tracks the chunks you supply and the longest line, not
/// the file.
///
/// Blank lines are skipped. Number-range failures fall back to
/// `jsonDecode` the way the whole-buffer path does. A truncated final
/// document throws [FormatException] with the same message. Records from
/// earlier chunks have already been yielded if a later line is malformed;
/// the whole-buffer APIs stay all-or-nothing.
///
/// Collecting the stream with `toList()` builds the same list the
/// whole-buffer path returns, and spends the memory this exists to avoid.
/// Fold each record and drop it.
///
/// ```dart
/// await for (final row in simdJsonDecodeNdjsonStream(input)) {
///   final record = row as Map<String, Object?>;
///   if (record['level'] == 'error') print(record['msg']);
/// }
/// ```
Stream<Object?> simdJsonDecodeNdjsonStream(Stream<List<int>> source) async* {
  final carry = _NdjsonCarry();
  await for (final chunk in source) {
    if (chunk.isEmpty) continue;
    final prefix = carry.add(chunk);
    if (prefix == null) continue;
    final values = simdJsonDecodeNdjsonBytes(prefix);
    carry.compact();
    for (final value in values) {
      yield value;
    }
  }
  final rest = carry.flush();
  if (rest != null) {
    for (final value in simdJsonDecodeNdjsonBytes(rest)) {
      yield value;
    }
  }
}

/// Decodes newline-delimited JSON from the file at [path], without
/// holding the file as a `Uint8List`.
///
/// `SimdJsonDocument.openFile` takes a path and reads it natively so a
/// large export never has to sit in Dart first. This is the NDJSON
/// equivalent: the file is read [chunkSize] bytes at a time (64 KiB by
/// default) and each complete document is yielded. A record longer than
/// [chunkSize] is still decoded; it is carried across reads until its
/// newline arrives.
///
/// ```dart
/// await for (final row in simdJsonDecodeNdjsonFile('requests.jsonl')) {
///   final record = row as Map<String, Object?>;
///   if (record['level'] == 'error') print(record['msg']);
/// }
/// ```
///
/// Throws [FormatException] when the path cannot be read, with
/// `IO_ERROR` in the message the way `SimdJsonDocument.openFile` reports
/// a missing file. A malformed or truncated document is a parse
/// [FormatException] without `IO_ERROR`. [chunkSize] must be at least 1.
Stream<Object?> simdJsonDecodeNdjsonFile(
  String path, {
  int chunkSize = _defaultChunkSize,
}) {
  if (chunkSize < 1) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be at least 1');
  }
  return simdJsonDecodeNdjsonStream(_readPath(path, chunkSize));
}

Stream<Uint8List> _readPath(String path, int chunkSize) async* {
  final RandomAccessFile handle;
  try {
    handle = await File(path).open();
  } on FileSystemException {
    throw FormatException('IO_ERROR: Error reading the file.', path);
  }
  try {
    while (true) {
      final Uint8List chunk;
      try {
        chunk = await handle.read(chunkSize);
      } on FileSystemException {
        throw FormatException('IO_ERROR: Error reading the file.', path);
      }
      if (chunk.isEmpty) break;
      yield chunk;
    }
  } finally {
    await handle.close();
  }
}

/// Bytes of an NDJSON stream that have not yet formed a complete line.
///
/// Invariant: after [compact], `_bytes[0, _length)` contains no 0x0A. A
/// new complete line can therefore only appear in the bytes just
/// appended, so the scan stays on the new chunk.
class _NdjsonCarry {
  Uint8List _bytes = Uint8List(0);
  int _length = 0;
  int _completeEnd = 0;

  /// Appends [chunk]. Returns a view of every complete line now held, or
  /// null if none. The view is valid until [compact] or the next [add].
  Uint8List? add(List<int> chunk) {
    final oldLength = _length;
    _ensure(_length + chunk.length);
    _bytes.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
    for (var i = _length - 1; i >= oldLength; i--) {
      if (_bytes[i] == _newline) {
        _completeEnd = i + 1;
        return Uint8List.sublistView(_bytes, 0, _completeEnd);
      }
    }
    return null;
  }

  /// Drops the complete lines [add] last returned, keeping only the
  /// unfinished tail. Call after those lines have been decoded: the view
  /// [add] returned is then invalid.
  void compact() {
    if (_completeEnd == 0) return;
    final remaining = _length - _completeEnd;
    if (remaining > 0) {
      _bytes.setRange(0, remaining, _bytes, _completeEnd);
    }
    _length = remaining;
    _completeEnd = 0;
  }

  /// Remaining bytes at end of stream, or null if there are none.
  Uint8List? flush() {
    if (_length == 0) return null;
    return Uint8List.sublistView(_bytes, 0, _length);
  }

  void _ensure(int needed) {
    if (needed <= _bytes.length) return;
    var capacity = _bytes.isEmpty ? needed : _bytes.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    final next = Uint8List(capacity);
    if (_length > 0) {
      next.setRange(0, _length, _bytes);
    }
    _bytes = next;
  }
}
