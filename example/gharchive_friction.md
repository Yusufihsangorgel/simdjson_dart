# Friction log: one GH Archive hour

Written while implementing `example/gharchive_report.dart` against
`data/2024-07-07-6.json.gz` (GH Archive, 2024-07-07 06:00 UTC: 48.2 MB
gzip, 346 MB uncompressed, 151,927 events). The public API was not
changed. Each item is a call that would have fit the job, the call the
surface actually offered, and where that showed up.

The file is heterogeneous on purpose. PushEvent has no `payload.action`.
119,263 of 151,927 events have no `org` key. 8,538 records carry a
`payload.pull_request` object: `merged` is sometimes absent, and
`base.repo.language` is a string or JSON null. Missing fields must not
crash the scan.

## 1. The file on disk is gzip; the File API reads raw NDJSON

Wanted:

```dart
await for (final row in simdJsonDecodeNdjsonFile('data/2024-07-07-6.json.gz')) {
  report.add(row);
}
```

Had to:

```dart
simdJsonDecodeNdjsonStream(file.openRead().transform(gzip.decoder));
```

Where: `example/gharchive_report.dart:127-129`. The uncompressed branch
still uses `simdJsonDecodeNdjsonFile` (`:131`), so the File API is not
dead — it just cannot take the file GH Archive actually publishes.

`SimdJsonDocument.openFile` on the `.gz` is worse than a missing-codec
error. It treats the gzip bytes as JSON and throws:

```
FormatException: UNESCAPED_CHARS: Within strings, some characters must
be escaped, we found unescaped characters
```

A caller who reached for `openFile` because the README says it "takes a
path and reads the file straight into the parser" has to already know
the path must be inflated JSON.

## 2. Selective access does not exist on the NDJSON path

The reason to reach for this package is `SimdJsonDocument.at('/repo/name')`
without building the rest of the document. GH events are that shape:
`payload.commits` and `payload.pull_request.body` are the bulk of a line
that can be 78 KB; the report wants `type`, `repo.name`, `actor.login`,
`payload.action`, and two fields under `payload.pull_request`.

Wanted: an NDJSON stream that yields a document, or that takes a list of
pointers. There is no such entry.

Had to, for the default decoder: fully materialize each event, then walk
the map.

```dart
await for (final row in _records(file, decoder)) {
  report.add(row);
}
```

Where: `example/gharchive_report.dart:98-100`. `add` then calls `_at` /
`_has` (`:246`, `:253`, `:260`, `:269`, `:273`, `:275`, `:278`, `:293`)
instead of `doc.at` / `doc.exists`.

The workaround is `--decoder=pointers`: split lines with `LineSplitter`,
`SimdJsonDocument.parse` each record, `at` / `exists`, `close`. That is
`_addFromPointers` (`:146-163`) and `addDocument` (`:312-365`). It is
the extraction the job wanted, assembled out of pieces the NDJSON API
does not combine. On this file it was *slower* than materializing every
event (9.70 s against 7.44 s). Full-decode NDJSON still beat
`jsonDecode` per line (14.32 s). Selective access is not free here
because each record is a separate parse and several FFI round-trips;
see (6) and (7).

## 3. `SimdJsonDocument.openFile` does not accept NDJSON

Wanted: open the hour once and walk records with pointers.

```dart
final doc = SimdJsonDocument.openFile('data/2024-07-07-6.json');
```

Had to: never call `openFile` on this dataset. Two concatenated events
(a 2-line NDJSON slice) throw:

```
FormatException: TAPE_ERROR: The JSON document has an improper
structure: missing or superfluous commas, braces, missing keys, etc.
```

The message does not say the input is more than one document, or that
`simdJsonDecodeNdjsonFile` is the matching entry. `parseBytes` on an
8 KB prefix that ends mid-record throws `UNCLOSED_STRING`, which is at
least accurate.

## 4. `at` / `exists` are not on the value the NDJSON APIs return

Wanted, per record:

```dart
doc.at('/repo/name');
doc.exists('/org');
doc.exists('/payload/pull_request/base/repo/language');
doc.at('/payload/pull_request/base/repo/language');
```

Had to, on the default path, reimplement both on `Map`:

```dart
Object? _at(Object? root, List<String> path) { ... }
bool _has(Object? root, List<String> path) { ... }
```

Where: `example/gharchive_report.dart:186-205`, used throughout `add`
(`:233-309`). The pointer versions exist only on `SimdJsonDocument`, so
`addDocument` (`:312-365`) is a second copy of the same extraction.

This is not cosmetic. Among 8,538 `pull_request` objects, `language` was
JSON null 903 times and never a missing key. `at` returns null for both.
The report has to call `exists` (or `_has`) first, which is exactly why
`exists` was added — and it is unreachable from `simdJsonDecodeNdjsonStream`.

`payload.action` is absent on 130,418 events (PushEvent, CreateEvent,
…). Nested `as Map` chains without a helper crash on those. The helper
is the API.

## 5. Getting bytes to `parseBytes` means giving up `LineSplitter`

Wanted:

```dart
final doc = SimdJsonDocument.parseBytes(lineBytes);
```

Had to:

```dart
final doc = SimdJsonDocument.parse(line);
```

Where: `example/gharchive_report.dart:151-157`. `LineSplitter` yields
`String`. `parse` UTF-8-encodes that string after the gzip decoder and
the UTF-8 decoder already produced it. `parseBytes` would skip the
re-encode if the split had been on `0x0A` in the byte stream — which is
what `simdJsonDecodeNdjsonStream` already does, internally, before it
builds a Dart object rather than a document.

## 6. A document per line has to be closed per line

Wanted: a stream whose handle dies with the iteration.

Had to:

```dart
final doc = SimdJsonDocument.parse(line);
try {
  report.addDocument(doc);
} finally {
  doc.close();
}
```

Where: `example/gharchive_report.dart:157-162`, 151,927 times. Forget
`close` and the native tape (on the order of the line, invisible to the
Dart GC) lives until the finalizer runs. The NDJSON full-decode path
does not have this handle. That is one reason it is the default in the
tool.

## 7. Each pointer is its own FFI round-trip

Wanted: six fields out of one record in one native call.

Had to, in `addDocument`: `at('/type')`, `at('/repo/name')`,
`at('/actor/login')`, `exists('/org')`, `exists('/payload/action')`,
`exists('/payload/pull_request')`, and then two more `exists`/`at`
pairs under `pull_request` (`:316-358`). On a hit, `exists` still
allocates a tape and frees it (`lib/src/document.dart:190-191`).

That is why `--decoder=pointers` lost to `--decoder=simdjson` on this
file even though it skips `payload.commits` and PR bodies. Average line
is 2.5 KB; the README crossover for `at` vs `jsonDecode` is about 2 KB
*and* assumes one parse, not one parse plus eight lookups.

## 8. A typed row cast does not describe both decoders

The README shows `row as Map<String, Object?>` for NDJSON. `jsonDecode`
produces `_Map<String, dynamic>`. simdjson produces `_Map<String, Object?>`.
On Dart 3.11 both `as` casts happened to succeed in both directions, so
this did not crash. A shared `add` still used `if (row is! Map)`
(`:241-244`) because the two runtime types are not the same and the
comparison has to run both backends.

## 9. A malformed line ends the stream

Wanted: count the bad record, keep scanning. GH Archive's hour did not
contain one, so this did not fire. The tool still has to wrap the loop
in `on FormatException` (`:102-109`) because `simdJsonDecodeNdjsonStream`
throws and does not resume. Records already yielded stay counted; the
rest of the hour is dropped. That is documented. It is the wrong default
for a log scanner, and there is no per-record `onError` on the stream.

---

Nothing above is a request to add symbols. It is the list of places the
surface made a real scan longer to write than the four JSON pointers the
scan is.
