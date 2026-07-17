import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'bindings.dart';
import 'decoder.dart';

/// A parsed JSON document held open for lazy access.
///
/// Where `simdJsonDecodeBytes` materializes the whole document into Dart
/// objects, a [SimdJsonDocument] parses once and materializes only the
/// subtrees you ask for. For the common backend pattern of reading a few
/// fields out of a large payload, this skips almost all of the object
/// construction cost.
///
/// ```dart
/// final doc = SimdJsonDocument.parseBytes(bytes);
/// try {
///   final name = doc.at('/items/0/name') as String?;
///   final total = doc.at('/meta/total') as int?;
/// } finally {
///   doc.close();
/// }
/// ```
///
/// Call [close] when done. Documents are also freed by a finalizer at
/// garbage collection, but the native memory (the parsed tape, roughly
/// the size of the input) is invisible to the Dart heap, so relying on
/// the GC can hold large buffers longer than expected.
final class SimdJsonDocument implements Finalizable {
  SimdJsonDocument._(this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  /// Parses [json] (UTF-8 bytes) and keeps the document open.
  ///
  /// Throws [FormatException] on invalid JSON.
  factory SimdJsonDocument.parseBytes(Uint8List json) {
    final padded = allocateBytes(json.length + 64);
    final result = allocateResult();
    try {
      padded.asTypedList(json.length + 64)
        ..setAll(0, json)
        ..fillRange(json.length, json.length + 64, 0);
      final handle = sjOpen(padded, json.length, result);
      if (handle == nullptr) {
        throw FormatException(errorMessageOf(result.ref));
      }
      return SimdJsonDocument._(handle);
    } finally {
      freeBytes(padded);
      freeResult(result);
    }
  }

  /// Parses a JSON string and keeps the document open.
  factory SimdJsonDocument.parse(String json) =>
      SimdJsonDocument.parseBytes(utf8.encode(json));

  static final NativeFinalizer _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      sjClose,
    ).cast(),
  );

  Pointer<Void> _handle;
  bool _closed = false;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Materializes the value at [jsonPointer] (RFC 6901), e.g.
  /// `/items/0/name`. The empty string returns the whole document.
  ///
  /// Returns null when the path does not exist (missing key, index out
  /// of bounds, or a scalar in the middle of the path). Throws
  /// [StateError] when the document is closed and [FormatException] for
  /// malformed pointers.
  Object? at(String jsonPointer) {
    if (_closed) {
      throw StateError('SimdJsonDocument has been closed');
    }
    final pointerBytes = utf8.encode(jsonPointer);
    final pointer = allocateBytes(pointerBytes.length);
    final result = allocateResult();
    try {
      pointer.asTypedList(pointerBytes.length).setAll(0, pointerBytes);
      sjAt(_handle, pointer, pointerBytes.length, result);
      final r = result.ref;
      if (r.errorCode == -1) return null; // Path not found.
      if (r.errorCode != 0) {
        throw FormatException(errorMessageOf(r), jsonPointer);
      }
      try {
        return decodeTape(r.tape.asTypedList(r.tapeLength));
      } finally {
        sjFree(r.tape);
      }
    } finally {
      freeBytes(pointer);
      freeResult(result);
    }
  }

  /// Releases the native document. Safe to call more than once.
  void close() {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    sjClose(_handle);
    _handle = nullptr;
  }
}
