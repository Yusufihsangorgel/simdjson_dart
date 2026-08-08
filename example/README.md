# simdjson_dart examples

One file per job the package does.

| File | Scenario |
|---|---|
| `simdjson_dart_example.dart` | Read a few fields out of a large JSON payload without turning the whole thing into Dart objects. |
| `ndjson_log_scan.dart` | Answer a real question about a newline-delimited log (`.jsonl`, `.ndjson`), first with the file resident and then in bounded memory. |

## Selective access: `simdjson_dart_example.dart`

Runs the scenario the package is built for. It builds a 3 MB paginated response
of 50,000 items, reads only the header and the first record with
`SimdJsonDocument.at`, then contrasts that with a full `jsonDecode`-compatible
decode and with how invalid input is rejected.

```dart
// Parse once, then read only the fields you ask for. The 49,999 records you
// never touch never become Dart maps.
final doc = SimdJsonDocument.parseBytes(bytes);
try {
  print(doc.at('/meta/total'));    // 50000
  print(doc.at('/items/0/name'));  // item-0
  print(doc.at('/meta/cursor'));   // null — a missing field is null, not an error
} finally {
  doc.close();                     // free the native document now, not at GC
}

// When you need most of the document, the full decode is jsonDecode-compatible:
final decoded = simdJsonDecodeBytes(bytes) as Map<String, Object?>;

// Invalid JSON throws a FormatException, so bad input never becomes a wrong value.
```

Run it:

```
dart run example/simdjson_dart_example.dart
```

Output:

```
payload: 3.0 MB
total:      50000
page:       1
first id:   0
first name: item-0
missing:    null
full-decode item count: 50000
rejected bad input: TAPE_ERROR: The JSON document has an improper structure: missing or superfluous commas, braces, missing keys, etc
```

`at` walks arrays from the front, so selective access wins near the top of the
document (a header, the first records); reach for the full decode when you need
most of it. The speedup for selective access is measured at 5–14x over a full
decode in the package README's benchmark.

## Newline-delimited logs: `ndjson_log_scan.dart`

Writes a 20,000-line request log to a temporary directory, then asks it how many
requests failed and which endpoint was slowest. The same question is answered
twice: once with the whole file in memory, once reading 64 KB at a time. Both
answers have to match, and the second one is where the interesting part is.

```dart
// The whole file, one native pass into simdjson. Reach for this first.
final rows = simdJsonDecodeNdjsonBytes(File(path).readAsBytesSync());

// Bigger than you want resident? Read in chunks — but never hand the decoder a
// fragment. Keep the bytes after the last newline and glue them onto the front
// of the next chunk. (Condensed; `_join`, `_lastNewlineIn` and the `onBatch`
// callback that folds each batch and drops it live in the file.)
final handle = File(path).openSync();
var carry = Uint8List(0);
while (true) {
  final chunk = handle.readSync(64 * 1024);
  if (chunk.isEmpty) break;                       // EOF
  final buffer = carry.isEmpty ? chunk : _join(carry, chunk);
  final cut = _lastNewlineIn(buffer);
  if (cut < 0) {
    carry = buffer;                               // a record longer than a chunk
    continue;
  }
  carry = Uint8List.fromList(Uint8List.sublistView(buffer, cut + 1));
  onBatch(simdJsonDecodeNdjsonBytes(Uint8List.sublistView(buffer, 0, cut + 1)));
}
if (carry.isNotEmpty) onBatch(simdJsonDecodeNdjsonBytes(carry));  // do not skip this
```

Run it:

```
dart run example/ndjson_log_scan.dart
```

Output:

```
log: 20000 lines, 2.16 MB

resident: 20000 rows, 399 errors, 6700 anonymous, slowest 999.7 ms on /api/検索
          peak buffer 2.16 MB — the whole file

chunked:  20000 rows, 399 errors, 6700 anonymous, slowest 999.7 ms on /api/検索
          peak buffer 64.1 KB — one chunk plus a partial line, 35x less than the file
          same answer as the resident pass: true

trap: a mid-line chunk throws — NDJSON input ends with an incomplete document
trap: a truncated log throws too — NDJSON input ends with an incomplete document
```

The log is generated from a fixed seed, so those numbers are the same on every
machine.

Two things the example is really about:

- **A chunk boundary is not a line boundary.** Hand
  `simdJsonDecodeNdjsonBytes` a buffer that stops mid-record and it rejects the
  whole batch with `NDJSON input ends with an incomplete document`. That is
  deliberate: simdjson's document stream would otherwise treat the trailing
  fragment as something a later batch will finish, which for a whole-buffer
  parse silently loses the last record of a cut-off log. Whether a boundary
  lands mid-record depends on the data, so this is the kind of bug that passes
  on a fixture and fails on production traffic.
- **The flush after the loop is not optional.** A log that does not end in a
  newline still has a real record sitting in the carry buffer. Deleting that
  last line turns the run into a quietly short answer rather than an error:
  with it removed, a 25-record file scans as 24 and a single-record file scans
  as 0, both with a zero exit code.

Splitting the raw bytes on `\n` without decoding them to a `String` first is
safe, because every byte of a multi-byte UTF-8 sequence has its high bit set —
`0x0A` can only ever be a real delimiter. The sample log carries non-ASCII
paths so the run exercises that; the slowest endpoint above is one of them.

For a log under about 100 KB, use `dart:convert`. The margin here comes from
making one trip into native code instead of one per line, and below that size
the FFI boundary costs more than it saves.
