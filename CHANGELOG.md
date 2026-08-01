## 1.2.1

- Ship the README section on standalone binaries, which 1.2.0 left out. It
  documents that `dart compile exe` refuses a package with build hooks and
  that `dart build` is the way through — the thing that stops this package's
  own audience, people building a CLI or a server binary, from shipping. It
  was committed alongside 1.2.0 but not in the archive that was published, and
  pub.dev renders the README from the archive, so the page did not show it.

## 1.2.0

- **Add `SimdJsonDocument.openFile`, which reads a file without it passing
  through Dart.** The package is for pulling a few fields out of a payload
  large enough that decoding all of it is the wrong trade — and until now the
  only way in was `parseBytes`, which needs the caller to hold the whole file
  as a `Uint8List` before anything is parsed, and then copies it again into
  the padded buffer simdjson works on. Two copies of the thing the package
  exists to avoid touching, and both grow with the file.

  `openFile` takes a path and lets simdjson read into that buffer directly.
  Measured on a 4.7 MB export, opening it and reading one pointer: 1.3 ms
  against 2.5 ms through `parseBytes`, with the intermediate list never built.
  It is a read rather than a memory map, so the bytes are paid for once and
  the file may change afterwards.

  A file that cannot be read and a file that is not JSON fail differently —
  `IO_ERROR` against a parse error — so a caller can tell a path to fix from
  data to fix.

## 1.1.2

- Lead with what this package is actually for. The description and the README
  opened on "fast JSON", which is the crowded claim and the weaker one: below
  about 100 KB `dart:convert` decodes a whole document faster than this can,
  FFI boundary included, and the README already said so further down. The one
  thing the built-in cannot do is skip — read three fields out of a 9 MB
  response and leave the rest as bytes. That is where the 5-14x is, so it is
  what the first sentence now says. No API or behaviour change.

## 1.1.1

- Document what a rejection costs, with `bench/reject.dart` behind it. A
  document that is invalid at its second byte is not rejected in constant
  time: the input is encoded and copied into native memory before simdjson
  looks at it, so at 4 MB a rejection costs 13 ms through `simdJsonDecode`
  and 0.9 ms through `simdJsonDecodeBytes`. That matters for a caller sitting
  in front of mixed input, which had no way to know it from the docs. No
  behaviour change.

## 1.1.0

- **Match `jsonDecode` on numbers simdjson will not represent.** An integer past
  `uint64` or an exponent that overflows to infinity is well-formed JSON that
  `dart:convert` accepts, and this package rejected it with a
  `FormatException` — a real gap for something whose pitch is returning the
  same shapes. `simdJsonDecode`, `simdJsonDecodeBytes` and both NDJSON entry
  points now hand the document to `jsonDecode` when simdjson failed *only* for
  a number's range (`NUMBER_ERROR` or `BIGINT_ERROR`, nothing wider), so
  `{"v": 18446744073709551616}` gives a double and `{"v": 1e400}` gives
  `Infinity`, both equal to `jsonDecode`. NDJSON retries line by line.

  The fix is on the Dart side on purpose. The C++ route — `number_as_string`
  plus a `BIGINT` case — is wrong at its own boundary: simdjson returns
  `INVALID_NUMBER` rather than `BIGINT_ERROR` for 20-digit positive overflows,
  so the whole window `[2^64, 10^20)` never becomes a big integer, and
  `parse_many` never receives the flag at all, which would leave the two entry
  points disagreeing. That asymmetry is filed upstream as simdjson/simdjson#2791.

  Cost is a second parse, and only for documents that previously threw; the
  check sits inside the existing error branch, so nothing changes when simdjson
  succeeds. Validation is not loosened: malformed input that fails for any
  other reason still throws, which the tests pin.

  `SimdJsonDocument`, the lazy reader, is unchanged and still throws — it
  returns a handle rather than a decoded value, so there is nothing to fall
  back to. Closes #3, reported via #1 by @arrrrny.

## 1.0.1

- Format the native-safety test added in 1.0.0. `test/` ships in the archive and
  pana scores its formatting, so the unformatted file would have cost points.
  No code or API change.

## 1.0.0

The API is stable. No behaviour changes; this freezes the surface after an
adversarial pass over the part that matters for a package holding native
memory, and pins what it found as tests.

Verified by execution and now covered by `test/native_safety_test.dart`:

- Using a closed document throws a `StateError` rather than reading freed
  memory, and closing twice is safe.
- Malformed input (empty, truncated, an unterminated string, a bad literal,
  runaway nesting) raises `FormatException`; none of it crashes the process.
- Parsing and closing 3,000 documents grows RSS by a few megabytes, not the
  hundreds a leak would cost.
- A document that is never closed is still reclaimed: growth over repeated
  batches builds up and then drops to under a megabyte once the GC runs the
  finalizer, which is what distinguishes a finalizer from a leak.

One honest caveat: the build hooks depend on `native_toolchain_c`, which is
pre-1.0, so a breaking release there may need a new build of this package. That
is a build-time dependency and does not reach the public API — the surface
frozen here is the Dart one.

## 0.2.6

- Add `example/README.md` for pub.dev's Example tab (it was empty). It walks
  through the selective-access example — read a few fields from a 3 MB payload
  without decoding the rest, then the full decode and the error path — with the
  real output. Docs only.

## 0.2.5

- Declare `platforms: {linux, macos, windows}` in `pubspec.yaml`. The build
  hook only ever runs `CBuilder` for the host toolchain and has no
  Android/iOS support today; pub.dev had inferred support for all five
  platforms from static analysis alone with no declaration to override it.

## 0.2.4

- Publish the crossover point. The benchmark table was only at 6-9 MB, which
  left the honest question unanswered: the FFI boundary is not free, so below
  some size dart:convert wins. `bench/crossover.dart` sweeps from 1 KB to 4 MB
  reading the same two fields through each engine, and the README now carries
  the curve. The crossover for the lazy `SimdJsonDocument.at` path is around
  2 KB: below it dart:convert decodes faster than it takes to cross into native
  code (0.4x at 1 KB), above it simdjson pulls away (5.7x at 4 KB to 10.4x at
  4 MB). This is the number to decide adoption on, and it says plainly: use it
  for reading part of a payload that is more than a few KB, not for small ones.

## 0.2.3

- Widen the native-toolchain constraints so the package can be installed in a
  Flutter app at all. `hooks` 2.1.0 and `native_toolchain_c` 0.19.3 raised their
  `meta` floor to ^1.19.0, and Flutter's SDK pins `meta` to 1.17.0, so
  `flutter pub add` failed at version solving with "flutter from sdk is
  incompatible". Allowing `hooks >=2.0.2` and `native_toolchain_c >=0.19.2`
  lets the solver pick a version that works with the pinned `meta`, while a
  pure-Dart project still resolves to the newest. No API or behaviour change.

## 0.2.2

- Shorten the screenshot description. pub.dev accepts up to 200 characters but
  scores only those under 160, so the previous release published cleanly and
  quietly gave up the documentation points it was meant to earn.

## 0.2.1

- Declare the benchmark chart in `pubspec.yaml` so pub.dev renders it on the
  package page. The chart was already in the repository and the README, but
  pub.dev shows only what the `screenshots:` field points at, so the page a
  reader lands on from search opened with text where the measurement should
  have been.

## 0.2.0

- Add `simdJsonDecodeNdjson` and `simdJsonDecodeNdjsonBytes` for
  newline-delimited JSON (`.ndjson`, `.jsonl`, log streams). The whole buffer
  goes to simdjson's document stream in one native pass and comes back as one
  decoded value per document, instead of a `jsonDecode` call per line. Measured
  at 10.4 ms against 17.8 ms on a 2.11 MB, 20,000-document log (Apple
  M-series, warmed up, five-run average), about 1.7x.
- A truncated last document is reported as a `FormatException` rather than
  dropped. simdjson's document stream treats trailing bytes that do not form a
  complete document as something a later batch will finish, which for a
  whole-buffer parse would silently lose the last record of a cut-off log.

## 0.1.3

- Example: rewrite it around the real use case. It now builds a multi-megabyte
  paginated payload and pulls a few fields (the page header and first record) by
  selective access, which is where the package is faster than a full decode,
  alongside the full-decode path and a rejected-input case.

## 0.1.2

- Docs: tightened the README and added an architecture diagram.

## 0.1.1

- Rename the example file to match the package name so pub.dev picks it
  up.

## 0.1.0

Initial release, vendoring simdjson 4.6.4.

- `SimdJsonDocument`: parse once, materialize only the subtrees you
  read, addressed by RFC 6901 JSON Pointers. 5-15x faster than full
  decoding when reading selected fields from large documents.
- `simdJsonDecodeBytes` / `simdJsonDecode`: whole-document decoding
  with the same result shapes as `jsonDecode`.
- Native code builds automatically via Dart build hooks (Dart 3.10+);
  no manual native setup.
