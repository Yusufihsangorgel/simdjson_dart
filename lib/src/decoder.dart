import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'bindings.dart';

/// Decodes a JSON string, like `jsonDecode` from `dart:convert`, but
/// parsed by the simdjson C++ library.
///
/// Returns the same shapes as `jsonDecode`: `Map<String, dynamic>`,
/// `List<dynamic>`, `String`, `int`, `double`, `bool`, or null. Throws
/// [FormatException] on invalid JSON.
Object? simdJsonDecode(String json) => simdJsonDecodeBytes(utf8.encode(json));

/// Like [simdJsonDecode], but takes UTF-8 bytes directly, skipping the
/// string-to-bytes conversion. Prefer this when the JSON arrives as
/// bytes (files, sockets, HTTP bodies).
Object? simdJsonDecodeBytes(Uint8List json) {
  // simdjson reads up to 64 bytes past the end (SIMDJSON_PADDING); give
  // it a padded copy so the read stays in bounds.
  final input = allocateBytes(json.length + 64);
  final result = allocateResult();
  try {
    input.asTypedList(json.length + 64)
      ..setAll(0, json)
      ..fillRange(json.length, json.length + 64, 0);
    sjParse(input, json.length, result);

    final r = result.ref;
    if (r.errorCode != 0) {
      throw FormatException(errorMessageOf(r), json);
    }
    try {
      return decodeTape(r.tape.asTypedList(r.tapeLength));
    } finally {
      sjFree(r.tape);
    }
  } finally {
    freeBytes(input);
    freeResult(result);
  }
}

/// Decodes newline-delimited JSON: one document per line, the shape log
/// files and data pipelines ship (`.ndjson`, `.jsonl`).
///
/// Returns one decoded value per document, in order, with the same shapes
/// `jsonDecode` returns. Blank lines are skipped. The whole input is parsed
/// in a single native pass, which is where this beats decoding each line
/// separately with `dart:convert`.
///
/// ```dart
/// final rows = simdJsonDecodeNdjson('{"a":1}\n{"a":2}\n');
/// print(rows.length); // 2
/// ```
///
/// Throws [FormatException] if any document is invalid; the message is
/// simdjson's own diagnostic.
List<Object?> simdJsonDecodeNdjson(String ndjson) =>
    simdJsonDecodeNdjsonBytes(utf8.encode(ndjson));

/// Like [simdJsonDecodeNdjson], but takes UTF-8 bytes directly. Prefer this
/// when the data arrives as bytes, which for NDJSON it usually does.
List<Object?> simdJsonDecodeNdjsonBytes(Uint8List ndjson) {
  // Same padding contract as simdJsonDecodeBytes: simdjson reads up to 64
  // bytes past the end.
  final input = allocateBytes(ndjson.length + 64);
  final result = allocateResult();
  try {
    input.asTypedList(ndjson.length + 64)
      ..setAll(0, ndjson)
      ..fillRange(ndjson.length, ndjson.length + 64, 0);
    sjParseNdjson(input, ndjson.length, result);

    final r = result.ref;
    if (r.errorCode != 0) {
      throw FormatException(errorMessageOf(r), ndjson);
    }
    try {
      return decodeTapeMany(r.tape.asTypedList(r.tapeLength));
    } finally {
      sjFree(r.tape);
    }
  } finally {
    freeBytes(input);
    freeResult(result);
  }
}

/// Decodes one tape buffer produced by the shim into Dart objects.
Object? decodeTape(Uint8List tape) => _TapeReader(tape).read();

/// Decodes a multi-document tape: a u32 count followed by that many values.
List<Object?> decodeTapeMany(Uint8List tape) {
  final reader = _TapeReader(tape);
  final count = reader._readU32();
  return List<Object?>.generate(count, (_) => reader.read(), growable: true);
}

/// Reads the error message out of a result struct.
String errorMessageOf(SjResult r) {
  if (r.errorMessage == nullptr) return 'simdjson error ${r.errorCode}';
  final bytes = r.errorMessage.cast<Uint8>();
  var length = 0;
  while (bytes[length] != 0) {
    length++;
  }
  return utf8.decode(bytes.asTypedList(length));
}

/// Allocates [bytes] of native memory. Throws [StateError] when the
/// allocation fails.
Pointer<Uint8> allocateBytes(int bytes) {
  // malloc(0) may legally return null; always request at least a byte.
  final pointer = _mallocNative(bytes < 1 ? 1 : bytes);
  if (pointer == nullptr) {
    throw StateError('native allocation of $bytes bytes failed');
  }
  return pointer.cast<Uint8>();
}

/// Frees memory from [allocateBytes].
void freeBytes(Pointer<Uint8> pointer) => _freeNative(pointer.cast());

/// Allocates an [SjResult]; the C side writes every field.
Pointer<SjResult> allocateResult() =>
    allocateBytes(sizeOf<SjResult>()).cast<SjResult>();

/// Frees a result from [allocateResult].
void freeResult(Pointer<SjResult> pointer) => _freeNative(pointer.cast());

@Native<Pointer<Void> Function(IntPtr)>(symbol: 'malloc')
external Pointer<Void> _mallocNative(int size);

@Native<Void Function(Pointer<Void>)>(symbol: 'free')
external void _freeNative(Pointer<Void> pointer);

/// Sequential reader for the tape format produced by the shim; see
/// src/simdjson_shim.cpp for the layout.
class _TapeReader {
  _TapeReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  /// Interned object keys. JSON arrays of objects repeat the same few
  /// keys thousands of times; decoding each occurrence separately is the
  /// single largest cost in object-heavy documents.
  final Map<int, List<_InternedKey>> _keys = {};

  Object? read() {
    final tag = _bytes[_offset++];
    switch (tag) {
      case 0x00:
        return null;
      case 0x01:
        return true;
      case 0x02:
        return false;
      case 0x03:
        final value = _view.getInt64(_offset, Endian.little);
        _offset += 8;
        return value;
      case 0x04:
        final value = _view.getFloat64(_offset, Endian.little);
        _offset += 8;
        return value;
      case 0x05:
        return _readString();
      case 0x06:
        final count = _readU32();
        return List<Object?>.generate(count, (_) => read(), growable: true);
      case 0x07:
        final count = _readU32();
        final map = <String, Object?>{};
        for (var i = 0; i < count; i++) {
          final key = _readKey();
          map[key] = read();
        }
        return map;
    }
    throw StateError('corrupt tape: unknown tag $tag at ${_offset - 1}');
  }

  int _readU32() {
    final value = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  String _readString() {
    final length = _readU32();
    final start = _offset;
    _offset = start + length;
    return _decodeString(start, length);
  }

  String _decodeString(int start, int length) {
    // ASCII fast path: no UTF-8 state machine needed, and the VM has an
    // optimized fromCharCodes for typed lists.
    final end = start + length;
    var ascii = true;
    for (var i = start; i < end; i++) {
      if (_bytes[i] >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (ascii) return String.fromCharCodes(_bytes, start, end);
    return utf8.decode(Uint8List.sublistView(_bytes, start, end));
  }

  String _readKey() {
    final length = _readU32();
    final start = _offset;
    _offset = start + length;

    var hash = 0x811c9dc5; // FNV-1a
    for (var i = start; i < start + length; i++) {
      hash = ((hash ^ _bytes[i]) * 0x01000193) & 0x7fffffff;
    }
    final bucket = _keys[hash];
    if (bucket != null) {
      candidates:
      for (final candidate in bucket) {
        final bytes = candidate.bytes;
        if (bytes.length != length) continue;
        for (var i = 0; i < length; i++) {
          if (bytes[i] != _bytes[start + i]) continue candidates;
        }
        return candidate.value;
      }
    }
    final key = _InternedKey(
      Uint8List.fromList(Uint8List.sublistView(_bytes, start, start + length)),
      _decodeString(start, length),
    );
    (_keys[hash] ??= []).add(key);
    return key.value;
  }
}

class _InternedKey {
  const _InternedKey(this.bytes, this.value);

  final Uint8List bytes;
  final String value;
}
