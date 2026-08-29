import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'decoder.dart';
import 'document.dart';

/// The NDJSON record delimiter. Splitting raw UTF-8 on this byte is safe:
/// every byte of a multi-byte sequence has its high bit set, so 0x0A is
/// never part of a character.
const _newline = 0x0A;

/// Default read size for [simdJsonDecodeNdjsonFile] and
/// [simdJsonSelectNdjsonFile]. Memory tracks this plus the longest line, not
/// the file.
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

/// Selects RFC 6901 [jsonPointers] from each NDJSON document in [source].
///
/// Each emitted map is keyed by the pointer strings supplied by the caller.
/// A missing path is omitted from the map, while a path whose value is JSON
/// null is present with a null value. Use `containsKey` to tell those cases
/// apart.
///
/// [existencePointers] checks paths without materializing their values. A hit
/// is included with the value true and a missing path is omitted. When the
/// same pointer appears in both iterables, the materialized [jsonPointers]
/// value wins, including when that value is JSON null.
///
/// Input stays as UTF-8 bytes: unfinished lines are carried across chunks and
/// complete lines are passed to [SimdJsonDocument.parseBytes] without a
/// string decode and re-encode. Blank lines are skipped. CRLF, a leading UTF-8
/// byte-order mark, and a final record without a newline are accepted.
/// Compressed input composes at the source, for example
/// `File(path).openRead().transform(gzip.decoder)` for gzip.
///
/// The native document for each line is closed before its map is emitted, so
/// callers never own a native handle and emitted maps remain valid after the
/// stream advances or ends. A malformed document or pointer stops the stream
/// with [FormatException]; values already emitted remain valid.
///
/// Like [SimdJsonDocument], this selective path does not fall back to a full
/// `jsonDecode` when a number is outside simdjson's range. Such a record throws
/// [FormatException].
///
/// API justification: friction log sections 2, 4, 5, and 6 required callers
/// to manually split, parse, query, and close every NDJSON line.
Stream<Map<String, Object?>> simdJsonSelectNdjsonStream(
  Stream<List<int>> source,
  Iterable<String> jsonPointers, {
  Iterable<String> existencePointers = const [],
}) async* {
  final pointers = List<String>.unmodifiable(jsonPointers);
  final existence = List<String>.unmodifiable(existencePointers);
  final carry = _NdjsonCarry();
  await for (final chunk in source) {
    if (chunk.isEmpty) continue;
    final prefix = carry.add(chunk);
    if (prefix == null) continue;
    for (final selected in _selectCompleteLines(prefix, pointers, existence)) {
      yield selected;
    }
    carry.compact();
  }
  final rest = carry.flush();
  if (rest != null) {
    final selected = _selectLine(rest, 0, rest.length, pointers, existence);
    if (selected != null) yield selected;
  }
}

Iterable<Map<String, Object?>> _selectCompleteLines(
  Uint8List bytes,
  List<String> pointers,
  List<String> existencePointers,
) sync* {
  var start = 0;
  for (var end = 0; end < bytes.length; end++) {
    if (bytes[end] != _newline) continue;
    final selected = _selectLine(
      bytes,
      start,
      end,
      pointers,
      existencePointers,
    );
    if (selected != null) yield selected;
    start = end + 1;
  }
}

Map<String, Object?>? _selectLine(
  Uint8List bytes,
  int start,
  int end,
  List<String> pointers,
  List<String> existencePointers,
) {
  if (_isBlankLine(bytes, start, end)) return null;
  final line = Uint8List.sublistView(bytes, start, end);
  final document = SimdJsonDocument.parseBytes(line);
  try {
    return document.atMany(pointers, existencePointers: existencePointers);
  } finally {
    document.close();
  }
}

bool _isBlankLine(Uint8List bytes, int start, int end) {
  for (var index = start; index < end; index++) {
    final byte = bytes[index];
    if (byte != 0x20 && byte != 0x09 && byte != 0x0D) return false;
  }
  return true;
}

/// Selects RFC 6901 pointers from raw, uncompressed NDJSON at [path].
///
/// This is the file counterpart of [simdJsonSelectNdjsonStream]. It reads
/// [chunkSize] bytes at a time (64 KiB by default), materializes
/// [jsonPointers], and reports hits from [existencePointers] as true without
/// materializing those subtrees. Missing pointers are omitted, and a pointer
/// present in both iterables keeps its materialized value.
///
/// The file is opened lazily when the returned stream is consumed. A missing
/// or unreadable file then throws [FormatException] with `IO_ERROR` in its
/// message. [chunkSize] must be at least 1 and is validated synchronously.
/// Compression and other codecs compose with [simdJsonSelectNdjsonStream]
/// instead; for gzip, pass
/// `File(path).openRead().transform(gzip.decoder)` as its source.
///
/// API justification: friction log section 3: matching file access was absent.
Stream<Map<String, Object?>> simdJsonSelectNdjsonFile(
  String path,
  Iterable<String> jsonPointers, {
  Iterable<String> existencePointers = const [],
  int chunkSize = _defaultChunkSize,
}) {
  if (chunkSize < 1) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be at least 1');
  }
  return simdJsonSelectNdjsonStream(
    _readPath(path, chunkSize),
    jsonPointers,
    existencePointers: existencePointers,
  );
}

/// Decodes newline-delimited JSON from the file at [path], without
/// holding the file as a `Uint8List`.
///
/// The file must contain raw, uncompressed NDJSON. Compression and other
/// codecs compose with [simdJsonDecodeNdjsonStream] instead; for gzip, pass
/// `File(path).openRead().transform(gzip.decoder)` as that stream's source.
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
