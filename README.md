![simdjson: fast JSON for Dart](https://raw.githubusercontent.com/Yusufihsangorgel/simdjson_dart/main/doc/banner.png)

# simdjson_dart

Fast JSON for Dart, powered by the [simdjson](https://simdjson.org) C++
library over FFI. The native code is compiled automatically at build
time through Dart build hooks; there is nothing to install.

Three APIs:

- **`SimdJsonDocument`** parses once and materializes only what you
  read. For picking fields out of large payloads this is 5-14x faster
  than decoding everything.
- **`simdJsonDecodeBytes`** is a `jsonDecode` alternative that decodes
  the whole document, moderately faster on large byte inputs.
- **`simdJsonDecodeNdjson`** decodes newline-delimited JSON (`.ndjson`,
  `.jsonl`, log streams) in a single native pass instead of one
  `jsonDecode` per line.

```dart
import 'package:simdjson_dart/simdjson_dart.dart';

// Selective access: parse 9 MB, materialize three values.
final doc = SimdJsonDocument.parseBytes(bytes);
try {
  final name = doc.at('/items/0/name') as String?;
  final price = doc.at('/items/20000/price') as double?;
  final tags = doc.at('/items/5/tags') as List?;
} finally {
  doc.close();
}

// Full decode, same shapes as jsonDecode.
final data = simdJsonDecodeBytes(bytes) as Map<String, dynamic>;

// Newline-delimited JSON: one value per line, one native pass.
final rows = simdJsonDecodeNdjsonBytes(logBytes);
```

## Newline-delimited JSON

Log files and data pipelines ship one JSON document per line. Decoding
those line by line means a `jsonDecode` call per record;
`simdJsonDecodeNdjson` hands the whole buffer to simdjson once and
returns one decoded value per document, in order. Blank lines are
skipped, and the shapes are the same ones `jsonDecode` returns.

```dart
final rows = simdJsonDecodeNdjson('{"level":"info"}\n{"level":"error"}\n');
print(rows.length); // 2
```

On a 2.11 MB log of 20,000 documents, measured on an Apple M-series
machine after warmup and averaged over five runs, that is 10.4 ms
against 17.8 ms for a `jsonDecode` per line, about 1.7x. Both
materialize every record, so this is the same moderate margin the
full-decode path gets, not the 5-14x that selective access gives.

A truncated last document is an error, not a silent drop. simdjson's
document stream normally treats trailing bytes that do not yet form a
complete document as something a later batch will finish, which for a
whole-buffer parse would quietly lose the last record of a cut-off log.
That case throws a `FormatException` here instead.

![Diagram: the lazy SimdJsonDocument.at path reads only selected fields, while simdJsonDecodeBytes does a full decode; both cross dart:ffi into native simdjson](https://raw.githubusercontent.com/Yusufihsangorgel/simdjson_dart/main/doc/architecture.png)

## Performance, honestly

Medians on an Apple Silicon MacBook (macOS arm64, Dart 3.11), synthetic
workloads from `bench/bench.dart`. Baseline is `dart:convert` doing the
same work, including reading the results (its maps materialize lazily).

![benchmark](https://raw.githubusercontent.com/Yusufihsangorgel/simdjson_dart/main/doc/bench.png)

| Workload (6.7-9.2 MB) | Read 3 values | Full decode + read all |
|---|---|---|
| API-like objects | **10.3x** | 1.19x |
| Number-heavy arrays | **5.4x** | 1.75x |
| String-heavy | **14.8x** | 1.21x |

What this means in practice:

- The big win is `SimdJsonDocument`: when you do not need every field,
  parse throughput reaches multiple GB/s because the skipped parts are
  never turned into Dart objects.
- Full decoding from bytes is 1.1-1.8x, best on number-heavy data
  (`dart:convert`'s number parsing is the slower path, see
  [dart-lang/sdk#55522]).
- If your input is already a Dart `String` and you decode all of it,
  `jsonDecode` is often *faster* than `simdJsonDecode`; the VM decodes
  UTF-16 strings natively while simdjson needs UTF-8 bytes. Keep using
  `dart:convert` there. Run `dart run bench/bench.dart` on your own
  data before switching.

[dart-lang/sdk#55522]: https://github.com/dart-lang/sdk/issues/55522

## API notes

- `doc.at(pointer)` takes an [RFC 6901 JSON Pointer]
  (`/items/0/name`, `~0`/`~1` escapes); the empty string returns the
  whole document. Missing paths return null.
- `close()` frees the native document (roughly input-sized memory the
  GC cannot see). A finalizer covers forgotten documents, but call
  `close` for anything large.
- Decoded values have the same runtime types as `jsonDecode`:
  `Map<String, dynamic>`, `List<dynamic>`, `String`, `int`, `double`,
  `bool`, null. Unsigned 64-bit values above `int` range come back as
  doubles, matching `jsonDecode`.
- Invalid JSON throws `FormatException` with simdjson's error message.
- Safe to use from multiple isolates; each thread keeps its own parser.
  A thread's parser retains its largest-seen buffer capacity for reuse.

[RFC 6901 JSON Pointer]: https://www.rfc-editor.org/rfc/rfc6901

## Differences from jsonDecode

simdjson validates strictly, so a few inputs `jsonDecode` accepts are
rejected with `FormatException` here:

- Numbers outside the representable range: `1e999` (jsonDecode returns
  `Infinity`) and integers beyond the unsigned 64-bit range (jsonDecode
  returns a double).
- Lone surrogate escapes such as `"\ud800"`.
- Nesting deeper than 1024 levels, and documents over 4 GB.

## Platform support

Dart 3.10+ with build hooks: `dart run`, `dart test`, and `dart build`
compile the C++ automatically (a C++17 toolchain must be present:
Xcode CLT, gcc/clang, or MSVC). Developed and verified on macOS arm64;
CI covers Linux, macOS, and Windows. Flutter support arrives when
build hooks land in stable Flutter.

## Credits and licenses

This package is MIT licensed. It vendors the
[simdjson](https://github.com/simdjson/simdjson) single-header
amalgamation (v4.6.4), Apache License 2.0; see
`src/third_party/simdjson/LICENSE`.
