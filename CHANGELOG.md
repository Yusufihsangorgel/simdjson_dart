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
