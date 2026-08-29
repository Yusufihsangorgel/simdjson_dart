![simdjson: fast JSON for Dart](https://raw.githubusercontent.com/Yusufihsangorgel/simdjson_dart/main/doc/banner.png)

# simdjson_dart

Read a few fields out of a large JSON payload without decoding the rest,
powered by the [simdjson](https://simdjson.org) C++ library over FFI. The
native code is compiled automatically at build time through Dart build hooks;
there is nothing to install.

![A terminal run of the benchmark: a 9.3 MB JSON API response, three fields
read out of it, `jsonDecode` plus indexing taking 71 ms against
`SimdJsonDocument.at` taking 6 ms, and the ratio printed underneath](https://raw.githubusercontent.com/Yusufihsangorgel/simdjson_dart/main/doc/demo.gif)

## Why this instead of what you already have

**Instead of `dart:convert`.** `jsonDecode` builds the entire tree before you
can read a single field. If a 6 MB response carries three values you care
about, you still pay to allocate every other string, list, and map in it.
`SimdJsonDocument.parseBytes` parses once and materializes only what you ask
for: `doc.at('/meta/total')` walks the parsed tape and hands back one Dart
object (`lib/src/document.dart:121`).

**Instead of `crimson`.** Crimson is the popular pure-Dart fast-JSON package
and it does support RFC 6901 pointers, but they are wired up at build time.
You annotate a class with `@json` and run `build_runner`, and its README notes
that "JSON pointers are evaluated at compile time and optimized code is
generated," and that "you can only use a pointer prefix once in a class"
(README, "JSON Pointers"). That is a good trade when you know the shape ahead
of time. It does not help when the path is a string you received at runtime,
or when you want both `/user` and `/user/name` out of the same payload.

**Reach for it when**

- A large upstream payload has a few fields you need and the rest is noise.
- The field path is data, from a config or a mapping table, not a literal in your source.
- You read NDJSON line by line and do not want each line's full object graph.

**Skip it** if your payloads are small or you need every field anyway:
`dart:convert` has no native build step and runs on web, which this package
does not (`pubspec.yaml` declares linux, macos, and windows only).

That first sentence is the whole point. Decoding a document into Dart objects
is work `dart:convert` already does well, and below about 100 KB it does it
faster than this package can, FFI boundary included. What it cannot do is
skip: pull three fields out of a 9 MB response and leave the other 9 MB as
bytes. That is where the 5-14x lives, and it is the reason to reach for this
rather than the built-in.

Three APIs:

- **`SimdJsonDocument`** parses once and materializes only what you
  read. `SimdJsonDocument.openFile` takes a path and reads the file straight
  into the parser: a large export never has to be held as a `Uint8List`
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
materialize every record. This is the same moderate margin the
full-decode path gets, rather than the 5-14x that selective access gives.

A truncated last document is an error, not a silent drop. simdjson's
document stream normally treats trailing bytes that do not yet form a
complete document as something a later batch will finish, which for a
whole-buffer parse would quietly lose the last record of a cut-off log.
That case throws a `FormatException` here instead.

That same guarantee decides how you read a log too large to hold. A chunked
read has to hand over whole lines only: keep the bytes after the last newline,
glue them onto the front of the next chunk, and flush that remainder at EOF. A
chunk that stops mid-record is rejected rather than half-parsed, and whether a
boundary lands mid-record depends on the data, so the mistake survives a
fixture and fails on real traffic. `example/ndjson_log_scan.dart` answers the
same question about a 20,000-line log twice, from a 2.16 MB resident buffer and
from a 64 KB one, and prints both.

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

The table above is at 6-9 MB. The FFI boundary is not free, and at small sizes
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
simdjson looks at them, so it scales with the document rather than with the
distance to the error. Rejecting a 4 MB document that is invalid at byte two:

| Size | `simdJsonDecode` | `simdJsonDecodeBytes` | 4 KB head scan |
| ---- | ---------------- | --------------------- | -------------- |
| 4 KB | 15 µs | 3.8 µs | 13 µs |
| 37 KB | 68 µs | 13 µs | 14 µs |
| 388 KB | 1.87 ms | 178 µs | 10 µs |
| 4 MB | 12.97 ms | 885 µs | 18 µs |

Two things follow. Hand over bytes rather than a `String` if you reject often;
most of the gap between the first two columns is the UTF-8 encode that
`simdJsonDecode` does for you. And if you can tell from the first few kilobytes
that a document is not strict JSON, checking is worth it above roughly 40 KB;
below that the scan costs about what the failed parse does.

The third column is a heuristic rather than a parse, and it can be wrong in
both directions. It is here because it is what a caller in front of mixed
input reaches for. Numbers from `dart run bench/reject.dart` on an Apple
M-series.

## API notes

- `doc.at(pointer)` takes an [RFC 6901 JSON Pointer]
  (`/items/0/name`, `~0`/`~1` escapes); the empty string returns the
  whole document.
- `doc.at(pointer)` returns null for two different facts: the path is not
  there, or its value is JSON null. `doc.exists(pointer)` separates them, and
  is cheaper than `at` on a hit because it never builds the Dart value.

  ```dart
  // {"nickname": null} -- the field is present and deliberately empty.
  doc.at('/nickname');      // null
  doc.exists('/nickname');  // true
  doc.at('/missing');       // null
  doc.exists('/missing');   // false
  ```

  It is the overload `Map` has, and it matters in the same places: an absent
  key usually means "use the default", an explicit null means "no value, and
  do not default".
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
simdjson succeeds. `SimdJsonDocument`, the lazy reader, still throws: it hands
back a handle rather than a decoded value, and there is nothing to fall back
to.

## Standalone binaries

`dart compile exe` does not run build hooks, so the native library never
ships. On Dart 3.13.2 (macOS arm64) the compile succeeds (exit 0) and the
binary then fails at startup (exit 255):

```
Invalid argument(s): Couldn't resolve native function 'sj_open' in 'package:simdjson_dart/src/bindings.dart' : No asset with id 'package:simdjson_dart/src/bindings.dart' found. No available native assets. Attempted to fallback to process lookup. dlsym(RTLD_DEFAULT, sj_open): symbol not found.
```

The same command used to stop at compile time with `'dart compile' does
not support build hooks, use 'dart build' instead`. Use `dart build cli`,
which runs the hook and copies the asset:

```
dart build cli --target example/simdjson_dart_example.dart
```

That reports `Copying 1 build assets: package:simdjson_dart/src/bindings.dart`
and writes a `bundle/` directory rather than a lone file:

```
build/cli/<os>_<arch>/bundle/bin/<name>
```

On macOS arm64 that is
`build/cli/macos_arm64/bundle/bin/simdjson_dart_example`. The executable
loads its library from `../lib` next to it; shipping only the file out of
`bin/` fails the same way as `dart compile exe`. Ship the whole folder.
`dart run` and `dart test` are unaffected.

Treat this as the intended path, not a gap waiting on a fix. `dart build
cli` is where the SDK points a package that carries build hooks, and the
open discussion on the `dart compile exe` side is about narrowing its
check for projects that merely *depend* on a hook they never invoke. It is
not about teaching it to run them ([dart-lang/sdk#62593]), so the compile
succeeding and the binary then failing at startup is not a reason to wait.

[dart-lang/sdk#62593]: https://github.com/dart-lang/sdk/issues/62593

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
