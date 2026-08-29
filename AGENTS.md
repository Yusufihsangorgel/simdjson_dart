# simdjson_dart

Read selected RFC 6901 pointers out of a large JSON payload without
materializing the rest, using simdjson over FFI. Full-document and NDJSON
decodes (`simdJsonDecode`, `simdJsonDecodeBytes`, `simdJsonDecodeNdjson`,
`simdJsonDecodeNdjsonBytes`) return the same shapes as `jsonDecode`.

Does not encode. Does not run on web, Android, iOS, or Flutter:
`pubspec.yaml` declares linux, macos, and windows; `hook/build.dart`
compiles the host C++ library only (`CBuilder`); stable Flutter does not
run Dart build hooks. Skip it for small payloads (crossover ~2 KB in
`bench/crossover.dart`) and for a Dart `String` you fully decode —
`jsonDecode` is faster there. simdjson rejects trailing commas, `NaN`,
lone surrogate escapes, nesting deeper than 1024, and documents over 4 GB.

## Usage

From `example/simdjson_dart_example.dart`:

```dart
import 'package:simdjson_dart/simdjson_dart.dart';

final doc = SimdJsonDocument.parseBytes(bytes);
try {
  print('total:      ${doc.at('/meta/total')}'); // 50000
  print('first name: ${doc.at('/items/0/name')}'); // item-0
  print('missing:    ${doc.at('/meta/cursor')}'); // null
} finally {
  doc.close();
}

final decoded = simdJsonDecodeBytes(bytes) as Map<String, Object?>;
```

NDJSON (`example/ndjson_log_scan.dart`):
`final rows = simdJsonDecodeNdjsonBytes(bytes);`

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
  Split on `0x0A`, keep the remainder; see `example/ndjson_log_scan.dart`.
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
dart test
dart run example/simdjson_dart_example.dart
dart run example/ndjson_log_scan.dart
```

FFI symbols in `lib/src/bindings.dart` must match the `SJ_EXPORT`
functions in `src/simdjson_shim.cpp`.
