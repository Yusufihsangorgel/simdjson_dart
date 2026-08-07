![simdjson: fast JSON for Dart](https://raw.githubusercontent.com/Yusufihsangorgel/simdjson_dart/main/doc/banner.png)

# simdjson_dart

Read a few fields out of a large JSON payload without decoding the rest,
powered by the [simdjson](https://simdjson.org) C++ library over FFI. The
native code is compiled automatically at build time through Dart build hooks;
there is nothing to install.

That first sentence is the whole point. Decoding a document into Dart objects
is work `dart:convert` already does well, and below about 100 KB it does it
faster than this package can, FFI boundary included. What it cannot do is
skip: pull three fields out of a 9 MB response and leave the other 9 MB as
bytes. That is where the 5-14x lives, and it is the reason to reach for this
rather than the built-in.

Three APIs:

- **`SimdJsonDocument`** parses once and materializes only what you
  read. `SimdJsonDocument.openFile` takes a path and reads the file straight
  into the parser, so a large export never has to be held as a `Uint8List`
  first. For picking fields out of large payloads this is 5-14x faster
  than decoding everything.
- **`simdJsonDecodeBytes`** is a `jsonDecode` alternative that decodes
  the whole document, moderately faster on large byte inputs.
- **`simdJsonDecodeNdjson`** decodes newline-delimited JSON (`.ndjson`,
  `.jsonl`, log streams) in a single native pass instead of one
  `jsonDecode` per line.

```dart
import 'package:simdjson_dart/simdjson_dart.dart';

// Selective access: parse 9 MB, materialize three values.
// Straight from a file, with no Uint8List in between:
//   final doc = SimdJsonDocument.openFile('export.json');
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

### Where the lazy path starts to pay off

The table above is at 6-9 MB. The FFI boundary is not free, so at small sizes
`dart:convert` wins; `bench/crossover.dart` sweeps the range to find where
`SimdJsonDocument.at` overtakes reading the same fields through `jsonDecode`:

![The lazy path overtakes jsonDecode at about 2 KB and pulls away with size, reaching 10x at 4 MB](https://raw.githubusercontent.com/Yusufihsangorgel/simdjson_dart/main/doc/crossover.png)

| Payload | jsonDecode + read | `SimdJsonDocument.at` | Winner |
|---|---|---|---|
| 1 KB | 0.004 ms | 0.009 ms | dart:convert 2.3x |
| 4 KB | 0.017 ms | 0.003 ms | **simd 5.7x** |
| 64 KB | 0.216 ms | 0.033 ms | **simd 6.5x** |
| 1 MB | 3.56 ms | 0.49 ms | **simd 7.3x** |
| 4 MB | 20.3 ms | 1.95 ms | **simd 10.4x** |

The crossover is around 2 KB. Below it, reach for `dart:convert`; a JSON that
small decodes faster than it takes to cross into native code. From a few KB up,
the lazy path wins and the gap widens with size.

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

### What a rejection costs

If you sit in front of mixed input, some of it will not be strict JSON and
every one of those pays for a `FormatException` instead of a result. That cost
is not constant: the bytes are encoded and copied into native memory before
simdjson looks at them, so it scales with the document, not with the distance
to the error. Rejecting a 4 MB document that is invalid at byte two:

| Size | `simdJsonDecode` | `simdJsonDecodeBytes` | 4 KB head scan |
| ---- | ---------------- | --------------------- | -------------- |
| 4 KB | 15 µs | 3.8 µs | 13 µs |
| 37 KB | 68 µs | 13 µs | 14 µs |
| 388 KB | 1.87 ms | 178 µs | 10 µs |
| 4 MB | 12.97 ms | 885 µs | 18 µs |

Two things follow. Hand over bytes rather than a `String` if you reject often —
most of the gap between the first two columns is the UTF-8 encode that
`simdJsonDecode` does for you. And if you can tell from the first few kilobytes
that a document is not strict JSON, checking is worth it above roughly 40 KB;
below that the scan costs about what the failed parse does.

The third column is a heuristic, not a parse, and it can be wrong in both
directions — it is here because it is what a caller in front of mixed input
reaches for. Numbers from `dart run bench/reject.dart` on an Apple M-series.

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

- Lone surrogate escapes such as `"\ud800"`.
- Nesting deeper than 1024 levels, and documents over 4 GB.

Numbers outside the range simdjson represents used to be on that list. They are
not any more: `simdJsonDecode`, `simdJsonDecodeBytes` and the NDJSON pair hand
the document to `jsonDecode` when simdjson rejects it *only* for a number's
range, so `1e999` gives `Infinity` and an integer past `uint64` gives a double,
exactly as `dart:convert` does. The retry costs a second parse, but only for
documents that would otherwise have thrown; nothing changes on the path where
simdjson succeeds. `SimdJsonDocument`, the lazy reader, still throws — it hands
back a handle rather than a decoded value, so there is nothing to fall back
to.

## Platform support

Dart 3.10+ with build hooks: `dart run`, `dart test`, and `dart build`
compile the C++ automatically (a C++17 toolchain must be present:
Xcode CLT, gcc/clang, or MSVC). Developed and verified on macOS arm64;
CI covers Linux, macOS, and Windows. Flutter support arrives when
build hooks land in stable Flutter.

### Standalone binaries

`dart compile exe` does not run build hooks, so it refuses a package that
needs them and stops with `'dart compile' does not support build hooks,
use 'dart build' instead`. Use `dart build` (in preview), which runs the
hooks and writes the native library beside the executable:

```
dart build cli
./build/cli/<os>_<arch>/bundle/bin/<name>
```

The output is a `bundle/` directory, not a lone file — the executable
loads its library from `../lib` next to it, so ship the whole folder.
`dart run` and `dart test` are unaffected.

Treat this as the intended path, not a gap waiting on a fix. `dart build
cli` is where the SDK points a package that carries build hooks, and the
open discussion on the `dart compile exe` side is about narrowing its
check for projects that merely *depend* on a hook they never invoke —
not about teaching it to run them ([dart-lang/sdk#62593]).

[dart-lang/sdk#62593]: https://github.com/dart-lang/sdk/issues/62593

## Credits and licenses

This package is MIT licensed. It vendors the
[simdjson](https://github.com/simdjson/simdjson) single-header
amalgamation (v4.6.4), Apache License 2.0; see
`src/third_party/simdjson/LICENSE`.
