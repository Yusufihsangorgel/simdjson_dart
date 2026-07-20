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
