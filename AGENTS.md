# simdjson_dart

Read selected RFC 6901 pointers out of a large JSON payload without
materializing the rest, using simdjson over FFI. Full-document and NDJSON
decodes (`simdJsonDecode`, `simdJsonDecodeBytes`, `simdJsonDecodeNdjson`,
`simdJsonDecodeNdjsonBytes`) return the same shapes as `jsonDecode`.
Streaming NDJSON (`simdJsonDecodeNdjsonStream`, `simdJsonDecodeNdjsonFile`)
yields one value per document without holding the whole input. The stream
entry accepts `Stream<List<int>>`; the file entry reads 64 KiB chunks by
default. Selective batching is `SimdJsonDocument.atMany`; selective NDJSON is
`simdJsonSelectNdjsonStream` / `simdJsonSelectNdjsonFile`. Their optional
`existencePointers` check exact paths without materializing those subtrees.

Does not encode. Does not run on web, Android, or iOS: `pubspec.yaml`
declares linux, macos, and windows, and `hook/build.dart` compiles the host
C++ library only (`CBuilder`). Do not repeat the old blanket claim that
stable Flutter cannot run build hooks: a Flutter 3.41.2 package test on
macOS resolves this package, builds the native asset, and executes a decode.
That is evidence for the declared macOS host only, not for undeclared mobile
or web targets. The measured selective-access crossover is ~2 KB in
`bench/crossover.dart`; for full decoding `dart:convert` wins below about
100 KB, and it is often faster when the input is already a Dart `String`.
simdjson rejects trailing commas, `NaN`, lone surrogate escapes, nesting
deeper than 1024, and documents over 4 GB.

## Usage

From `example/simdjson_dart_example.dart`:

```dart
import 'package:simdjson_dart/simdjson_dart.dart';

final doc = SimdJsonDocument.parseBytes(bytes);
try {
  final selected = doc.atMany(
    ['/meta/total', '/items/0/name'],
    existencePointers: ['/meta/cursor'],
  );
  print('total:      ${selected['/meta/total']}'); // 50000
  print('first name: ${selected['/items/0/name']}'); // item-0
  print('has cursor: ${selected.containsKey('/meta/cursor')}'); // false
} finally {
  doc.close();
}

final decoded = simdJsonDecodeBytes(bytes) as Map<String, Object?>;
```

NDJSON (`example/ndjson_log_scan.dart`):
`final rows = simdJsonDecodeNdjsonBytes(bytes);`
Streaming (`example/ndjson_stream.dart`):
`await for (final row in simdJsonDecodeNdjsonFile(path)) { print(row); }`
Selective file streaming:

```dart
await for (final selected in simdJsonSelectNdjsonFile(
  path,
  ['/repo/name'],
  existencePointers: ['/org'],
)) {
  print(selected['/repo/name']);
  print(selected.containsKey('/org'));
}
```

Also: `SimdJsonDocument.parse(String)`, `SimdJsonDocument.openFile(path)`
(native file read, no `Uint8List` of the contents). Pointers are RFC 6901
(`/items/0/name`); `""` is the whole document; `~1` / `~0` escape `/` / `~`.

## Contracts

- **`SimdJsonDocument.close`**. Frees the native document (about the size
  of the input, invisible to the Dart GC). A finalizer runs if you forget;
  call `close` for anything large. Idempotent. `isClosed` reports it.
  Values already returned by `at` are ordinary Dart objects and stay valid.
- **`SimdJsonDocument.at` / `exists`**. After `close`, both throw
  `StateError` (`SimdJsonDocument has been closed`). `at` returns null for
  a missing path and for JSON null; `exists` is true for an explicit null.
  A malformed pointer is `FormatException`, not null. `at` materializes the
  whole subtree — `at('')` or `at('/items')` on a large array is a full
  decode of that node.
- **`SimdJsonDocument.atMany`**. Resolves value pointers and optional
  `existencePointers` in one native batch. Value pointers materialize their
  values; existence-only hits are true without materializing the subtree.
  Missing paths are omitted. A pointer in both collections keeps its value,
  including JSON null. After `close` it throws `StateError`; a malformed
  pointer throws `FormatException`.
- **`SimdJsonDocument.parse` / `parseBytes` / `openFile`**. Invalid JSON
  is `FormatException` with simdjson's message. `openFile` on a missing
  path: `FormatException: IO_ERROR: Error reading the file.` A malformed
  file is a parse `FormatException` without `IO_ERROR`. These factories
  do not retry through `jsonDecode`.
- **`simdJsonDecode` / `simdJsonDecodeBytes` / `simdJsonDecodeNdjson` /
  `simdJsonDecodeNdjsonBytes`**. No close. On simdjson number-range
  failures they retry with `jsonDecode`; other errors still throw. NDJSON
  skips blank lines; empty input is `[]`; a truncated last document throws.
  Pass only complete lines (carry a mid-line tail, flush it at EOF).
- **`simdJsonDecodeNdjsonStream` / `simdJsonDecodeNdjsonFile`**. No close.
  A `Stream<Object?>` of the same shapes. The stream API accepts
  `Stream<List<int>>` and carries an unfinished line (including a split
  UTF-8 character) across chunks. The file API takes a path like `openFile`;
  `chunkSize` defaults to 64 KiB and values below 1 throw `ArgumentError`
  synchronously. Empty input yields nothing. A truncated last document
  still throws. Records from earlier chunks have already been yielded if a
  later chunk is malformed; complete lines batched in that failing chunk
  are not yielded. `toList()` undoes the memory bound. File opening is lazy:
  a missing-file `FormatException` with `IO_ERROR` arrives while the stream
  is consumed, so put `await for` or `await stream.toList()` inside the
  `try` block.
- **`simdJsonSelectNdjsonStream` / `simdJsonSelectNdjsonFile`**. The same
  bounded byte carry/file reading, but each row is a pointer-keyed
  `Map<String, Object?>`. Both accept value pointers plus optional
  `existencePointers`; the file entry reads raw NDJSON and has the same lazy
  `IO_ERROR` and positive `chunkSize` contract as the full-decode file entry.
  No close. These selective APIs do not retry number-range failures through a
  full `jsonDecode`.
- Shapes match `jsonDecode`. Maps and lists are growable. `uint64` above
  `int64` is a `double`. Safe from multiple isolates (per-thread parser).

## Mistakes

- **`doc['a']` or `doc.at('meta.total')`.** Analyzer: `The operator '[]'
  isn't defined for the type 'SimdJsonDocument'.` Pointer:
  `FormatException: INVALID_JSON_POINTER: Invalid JSON pointer syntax.`
  Use `at('/a')`, `at('/meta/total')`.
- **`at` / `exists` after `close`.**
  `Bad state: SimdJsonDocument has been closed`. Read, then `close`.
- **`doc.at('/missing') as String`.**
  `type 'Null' is not a subtype of type 'String' in type cast`.
  Cast `as String?`. If JSON null vs absent matters, call `exists` first.
- **NDJSON buffer that ends mid-record.**
  `FormatException: NDJSON input ends with an incomplete document`.
  The whole-buffer APIs need complete lines. Use
  `simdJsonDecodeNdjsonStream` / `simdJsonDecodeNdjsonFile`, which carry
  the tail; see `example/ndjson_stream.dart`.
- **Catching around `simdJsonDecodeNdjsonFile(path)` without consuming it.**
  The call only creates a stream, so it does not open the file and the catch
  sees nothing. Catch around `await for` or `await ...toList()` instead.
- **Collecting a large NDJSON stream.** `await stream.toList()` is correct,
  but it retains every decoded row. Fold/process each row in `await for` if
  bounded memory is the reason for using the streaming API.
- **`SimdJsonDocument.parse` on an integer past uint64.**
  `FormatException: NUMBER_ERROR: Problem while parsing a number`.
  Use `simdJsonDecode` / `simdJsonDecodeBytes` (they fall back to
  `jsonDecode`). The lazy document has nothing to fall back to.
- **Trailing comma, `NaN`, `"\ud800"`.**
  `FormatException: TAPE_ERROR: The JSON document has an improper structure: missing or superfluous commas, braces, missing keys, etc.`
  or `STRING_ERROR: Problem while parsing a string`. Stricter than
  `jsonDecode`; do not treat a swap as a drop-in for lax input.
- **`dart compile exe`.** Compile can succeed; the binary then fails with
  `Invalid argument(s): Couldn't resolve native function 'sj_open' in 'package:simdjson_dart/src/bindings.dart' : No asset with id 'package:simdjson_dart/src/bindings.dart' found.`
  Use `dart run` / `dart test`, or `dart build cli` and ship the whole
  `bundle/` (the executable loads `../lib`).

## Layout

```
lib/simdjson_dart.dart   public exports only
lib/src/document.dart    SimdJsonDocument
lib/src/decoder.dart     simdJsonDecode*
lib/src/ndjson_stream.dart  full-decode/selective NDJSON stream + file
lib/src/bindings.dart    @Native FFI (not exported)
src/simdjson_shim.cpp    C ABI
src/third_party/simdjson vendored amalgamation
hook/build.dart          CBuilder.library, C++17, assetName src/bindings.dart
example/                 usage
test/                    dart test
```

`dart run`, `dart test`, and `dart build` compile the shim; a C++17
toolchain must be present (Xcode CLT, gcc/clang, or MSVC). SDK `^3.10.0`.

```
dart pub get
dart format .
dart analyze
dart test
dart run example/simdjson_dart_example.dart
dart run example/ndjson_log_scan.dart
dart run example/ndjson_stream.dart
```

FFI symbols in `lib/src/bindings.dart` must match the `SJ_EXPORT`
functions in `src/simdjson_shim.cpp`.
