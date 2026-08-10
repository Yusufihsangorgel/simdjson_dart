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

  /// Opens the JSON file at [path] and keeps the document open.
  ///
  /// [parseBytes] needs its caller to hold the whole file as a `Uint8List`
  /// first, and then copies it again into the padded buffer simdjson parses.
  /// This reads the file into that buffer directly, so the intermediate list
  /// is never built — one copy rather than two, and nothing the Dart
  /// collector has to account for afterwards. Measured on a 4.7 MB export,
  /// opening it and reading one pointer: 1.3 ms against 2.5 ms.
  ///
  /// It is a read, not a memory map: the bytes are paid for once and the file
  /// is free to change afterwards. What is saved is the trip through Dart,
  /// which is the whole file and grows with it.
  ///
  /// ```dart
  /// final doc = SimdJsonDocument.openFile('export.json');
  /// try {
  ///   print(doc.at('/meta/generatedAt'));
  /// } finally {
  ///   doc.close();
  /// }
  /// ```
  ///
  /// Throws [FormatException] when the file cannot be read or does not hold
  /// valid JSON; the message carries simdjson's reason, so a missing file and
  /// a malformed one are told apart by what it says.
  factory SimdJsonDocument.openFile(String path) {
    final encoded = utf8.encode(path);
    final pathBytes = allocateBytes(encoded.length);
    final result = allocateResult();
    try {
      pathBytes.asTypedList(encoded.length).setAll(0, encoded);
      final handle = sjOpenFile(pathBytes, encoded.length, result);
      if (handle == nullptr) {
        throw FormatException(errorMessageOf(result.ref));
      }
      return SimdJsonDocument._(handle);
    } finally {
      freeBytes(pathBytes);
      freeResult(result);
    }
  }

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
  ///
  /// Null is two answers here, and this method does not tell them apart: a
  /// path that is not in the document and a path whose value *is* JSON null
  /// both come back as null. It is the same overload `Map` has, and it has
  /// the same fix -- ask [exists] when the difference matters:
  ///
  /// ```dart
  /// // {"nickname": null} -- the field is there and deliberately empty.
  /// doc.at('/nickname');      // null
  /// doc.exists('/nickname');  // true
  /// doc.at('/missing');       // null
  /// doc.exists('/missing');   // false
  /// ```
  ///
  /// Config files and API payloads use the distinction: an absent key means
  /// "take the default", an explicit null means "no value, do not default".
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

  /// Whether [jsonPointer] resolves to anything in this document.
  ///
  /// True for a path whose value is JSON null; that value exists. The point
  /// of this method is to separate it from a path that is not there, which
  /// [at] cannot do because both are null.
  ///
  /// Cheaper than [at] on a hit: the pointer is resolved the same way, but
  /// the value is never turned into a Dart object.
  ///
  /// Throws [StateError] when the document is closed and [FormatException]
  /// for a malformed pointer -- the same conditions as [at], so a pointer
  /// this accepts is one [at] will accept.
  bool exists(String jsonPointer) {
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
      if (r.errorCode == -1) return false; // Path not found.
      if (r.errorCode != 0) {
        throw FormatException(errorMessageOf(r), jsonPointer);
      }
      // The tape was allocated even though nothing here decodes it.
      sjFree(r.tape);
      return true;
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
