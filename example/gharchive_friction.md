# Friction log: one GH Archive hour

Written while implementing `example/gharchive_report.dart` against
`data/2024-07-07-6.json.gz` (GH Archive, 2024-07-07 06:00 UTC: 48.2 MB
gzip, 346 MB uncompressed, 151,927 events). This is now a record of both
what the original implementation exposed and what version 1.6.0 did about it.
Historical file and line references below point to that original
implementation; the example has since been updated to use the new API.

The file is heterogeneous on purpose. PushEvent has no `payload.action`.
119,263 of 151,927 events have no `org` key. 8,538 records carry a
`payload.pull_request` object: `merged` is sometimes absent, and
`base.repo.language` is a string or JSON null. Missing fields must not
crash the scan.

Three public symbols came out of the run, and no others:

- **API justification — `SimdJsonDocument.atMany`: friction-log §4, “`at` /
  `exists` are not on the value the NDJSON APIs return,” and §7, “Each pointer
  is its own FFI round-trip.”** The document already resolved value and
  existence pointers, but the caller could not batch either kind in one native
  call.
- **API justification — `simdJsonSelectNdjsonStream`: friction-log §2,
  “Selective access does not exist on the NDJSON path”; §4, “`at` / `exists`
  are not on the value the NDJSON APIs return”; §5, “Getting bytes to
  `parseBytes` means giving up `LineSplitter`”; and §6, “A document per line
  has to be closed per line.”** The NDJSON stream already found complete
  records as bytes, but selective access was not reachable there without
  rebuilding its splitting, handle, lookup, and cleanup work in the caller.
- **API justification — `simdJsonSelectNdjsonFile`: friction-log §3,
  “`SimdJsonDocument.openFile` does not accept NDJSON.”** Selective NDJSON had
  no path-shaped entry matching the existing full-decode file abstraction.

## 1. The file on disk is gzip; the File API reads raw NDJSON

**Status: DELIBERATELY NOT FIXED.** Gzip decoding remains an explicit
`dart:convert` transform because Dart already supplies the codec and making a
file API infer extensions or choose codecs would add a new policy to this
package. The same transform now feeds `simdJsonSelectNdjsonStream` in the
selective branch.

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

Where in the original implementation:
`example/gharchive_report.dart:127-129`. The uncompressed branch still used
`simdJsonDecodeNdjsonFile` (`:131`), so the File API was not dead — it just
could not take the file GH Archive actually publishes.

`SimdJsonDocument.openFile` on the `.gz` was worse than a missing-codec error.
It treated the gzip bytes as JSON and threw:

```
FormatException: UNESCAPED_CHARS: Within strings, some characters must
be escaped, we found unescaped characters
```

A caller who reached for `openFile` because the README said it “takes a path
and reads the file straight into the parser” had to already know the path must
be inflated JSON.

## 2. Selective access does not exist on the NDJSON path

**Status: FIXED by `simdJsonSelectNdjsonStream`.** It accepts a byte stream and
an iterable of RFC 6901 pointers, then yields one pointer/value map per NDJSON
record without materializing unrequested subtrees. The original measurements
below describe the hand-built workaround, not the new API; no replacement
measurement was made for this record.

The reason to reach for this package is `SimdJsonDocument.at('/repo/name')`
without building the rest of the document. GH events are that shape:
`payload.commits` and `payload.pull_request.body` are the bulk of a line that
can be 78 KB; the report wants `type`, `repo.name`, `actor.login`,
`payload.action`, and two fields under `payload.pull_request`.

Wanted: an NDJSON stream that yields a document, or that takes a list of
pointers. There was no such entry.

Had to, for the default decoder: fully materialize each event, then walk the
map.

```dart
await for (final row in _records(file, decoder)) {
  report.add(row);
}
```

Where in the original implementation:
`example/gharchive_report.dart:98-100`. `add` then called `_at` / `_has`
(`:246`, `:253`, `:260`, `:269`, `:273`, `:275`, `:278`, `:293`) instead of
`doc.at` / `doc.exists`.

The workaround was `--decoder=pointers`: split lines with `LineSplitter`,
`SimdJsonDocument.parse` each record, `at` / `exists`, `close`. That was
`_addFromPointers` (`:146-163`) and `addDocument` (`:312-365`). It was the
extraction the job wanted, assembled out of pieces the NDJSON API did not
combine. On this file it was *slower* than materializing every event (9.70 s
against 7.44 s). Full-decode NDJSON still beat `jsonDecode` per line
(14.32 s). Selective access was not free there because each record was a
separate parse and several FFI round-trips; see (6) and (7).

The current pointer branch is the direct call the original extraction wanted:

```dart
await for (final selected in simdJsonSelectNdjsonStream(
  bytes,
  valuePointers,
  existencePointers: existencePointers,
)) {
  report.addSelected(selected);
}
```

## 3. `SimdJsonDocument.openFile` does not accept NDJSON

**Status: FIXED by `simdJsonSelectNdjsonFile`.** `openFile` remains the
single-document abstraction, while the new path-shaped selector streams raw
NDJSON in chunks and returns the same pointer maps as
`simdJsonSelectNdjsonStream`. Compressed input still composes through the
stream entry because §1 deliberately leaves codec policy outside the file API.

Wanted: open the hour once and walk records with pointers.

```dart
final doc = SimdJsonDocument.openFile('data/2024-07-07-6.json');
```

Had to: never call `openFile` on this dataset. Two concatenated events (a
2-line NDJSON slice) throw:

```
FormatException: TAPE_ERROR: The JSON document has an improper
structure: missing or superfluous commas, braces, missing keys, etc.
```

The message does not say the input is more than one document, or that
`simdJsonDecodeNdjsonFile` is the matching entry. `parseBytes` on an 8 KB
prefix that ends mid-record throws `UNCLOSED_STRING`, which is at least
accurate. That evidence remains, but the fix keeps the single-document and
NDJSON abstractions separate instead of changing `openFile`:

```dart
await for (final selected in simdJsonSelectNdjsonFile(
  'data/2024-07-07-6.json',
  valuePointers,
  existencePointers: existencePointers,
)) {
  report.addSelected(selected);
}
```

## 4. `at` / `exists` are not on the value the NDJSON APIs return

**Status: FIXED by the `existencePointers` option on `atMany`,
`simdJsonSelectNdjsonStream`, and `simdJsonSelectNdjsonFile`.** Value pointers
materialize their values. Existence pointers are resolved in the same native
batch without materializing a large subtree merely to ask whether it exists.
A resolved existence-only path is present with the value true; a missing path
is absent, so `containsKey(pointer)` provides exact `exists` semantics. A
pointer may be in both collections when the caller needs its value and its
presence, as with a field whose value can be JSON null; the materialized value
wins in that case.

Wanted, per record:

```dart
doc.at('/repo/name');
doc.exists('/org');
doc.exists('/payload/pull_request/base/repo/language');
doc.at('/payload/pull_request/base/repo/language');
```

Had to, on the original default path, reimplement both on `Map`:

```dart
Object? _at(Object? root, List<String> path) { ... }
bool _has(Object? root, List<String> path) { ... }
```

Where in the original implementation:
`example/gharchive_report.dart:186-205`, used throughout `add` (`:233-309`).
The pointer versions existed only on `SimdJsonDocument`, so `addDocument`
(`:312-365`) was a second copy of the same extraction.

This was not cosmetic. Among 8,538 `pull_request` objects, `language` was JSON
null 903 times and never a missing key. `at` returns null for both. The report
had to call `exists` (or `_has`) first, which is exactly why `exists` was added
— and it was unreachable from `simdJsonDecodeNdjsonStream`.

`payload.action` is absent on 130,418 events (PushEvent, CreateEvent, …).
Nested `as Map` chains without a helper crash on those. The selective branch
now asks exact existence for `/org`, `/payload/action`,
`/payload/pull_request`, `/payload/pull_request/merged`, and
`/payload/pull_request/base/repo/language`; it no longer substitutes an ID
child as a sentinel. The full-decode comparison branches still walk their
materialized maps because that is the workload they measure.

## 5. Getting bytes to `parseBytes` means giving up `LineSplitter`

**Status: FIXED by `simdJsonSelectNdjsonStream`.** It carries unfinished raw
bytes across chunks and splits complete NDJSON records before parsing, so the
caller no longer converts each line to `String` only for `parse` to encode it
back to UTF-8.

Wanted:

```dart
final doc = SimdJsonDocument.parseBytes(lineBytes);
```

Had to:

```dart
final doc = SimdJsonDocument.parse(line);
```

Where in the original implementation:
`example/gharchive_report.dart:151-157`. `LineSplitter` yields `String`.
`parse` UTF-8-encoded that string after the gzip decoder and the UTF-8 decoder
already produced it. `parseBytes` would have skipped the re-encode if the
split had been on `0x0A` in the byte stream — which is what
`simdJsonDecodeNdjsonStream` already did internally before it built a Dart
object rather than a document.

## 6. A document per line has to be closed per line

**Status: FIXED by `simdJsonSelectNdjsonStream`.** Per-record native state is
internal to the iteration and is released before the selected map is yielded;
the caller receives ordinary Dart values and has no handle to close. This does
not weaken `SimdJsonDocument.close`: callers that explicitly open a document
must still close it.

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

Where in the original implementation:
`example/gharchive_report.dart:157-162`, 151,927 times. Forget `close` and the
native tape (on the order of the line, invisible to the Dart GC) lives until
the finalizer runs. The NDJSON full-decode path did not have this handle. That
was one reason it was the default in the original tool.

## 7. Each pointer is its own FFI round-trip

**Status: FIXED by `SimdJsonDocument.atMany`.** It resolves value pointers and
optional `existencePointers` in one native call. Value pointers materialize
their values; existence-only hits are true without materializing the pointed
subtree. Missing paths are omitted, and a pointer requested in
both modes keeps its value, preserving JSON null versus missing through
`containsKey`.

Wanted: six fields out of one record in one native call.

Had to, in the original `addDocument`: `at('/type')`, `at('/repo/name')`,
`at('/actor/login')`, `exists('/org')`, `exists('/payload/action')`,
`exists('/payload/pull_request')`, and then two more `exists`/`at` pairs under
`pull_request` (`example/gharchive_report.dart:316-358`). On a hit, `exists`
still allocated a tape and freed it (`lib/src/document.dart:190-191` in the
original implementation).

That is why the original `--decoder=pointers` lost to
`--decoder=simdjson` on this file even though it skipped `payload.commits` and
PR bodies. Average line is 2.5 KB; the README crossover for `at` versus
`jsonDecode` is about 2 KB *and* assumes one parse, not one parse plus eight
lookups.

The native batch change was required for §7's one-call lookup and §4's exact
existence checks without subtree materialization. Neither could be implemented
honestly by looping over the existing Dart `at` method. The other friction
items did not require C/C++ changes. No new performance measurement is claimed
for the batch API here.

## 8. A typed row cast does not describe both decoders

**Status: DELIBERATELY NOT FIXED.** Both decoders honor the public
`jsonDecode`-compatible `Map` contract; their private runtime implementation
types do not justify a package typedef or another public wrapper when
`dart:core`'s `Map` already expresses the common boundary.

The README showed `row as Map<String, Object?>` for NDJSON. `jsonDecode`
produced `_Map<String, dynamic>`. simdjson produced
`_Map<String, Object?>`. On Dart 3.11 both `as` casts happened to succeed in
both directions, so this did not crash. A shared `add` still used
`if (row is! Map)` (`example/gharchive_report.dart:241-244` in the original
implementation) because the two runtime types were not the same and the
comparison had to run both backends.

The shared full-decode comparison continues to check `row is Map`. The
selective API has its own precise return type, `Map<String, Object?>`, because
its keys are requested pointer strings rather than decoded object keys.

## 9. A malformed line ends the stream

**Status: DELIBERATELY NOT FIXED.** Continuing needs a recovery contract that
has not been chosen: whether to skip, what error and raw-record context to
report, and what happens to valid records sharing a native batch. That is a
new error-recovery subsystem, not a small method exposing an existing
capability.

Wanted: count the bad record, keep scanning. GH Archive's hour did not contain
one, so this did not fire. The original tool still had to wrap the loop in
`on FormatException` (`example/gharchive_report.dart:102-109`) because
`simdJsonDecodeNdjsonStream` throws and does not resume. Records already
yielded stay counted; the rest of the hour is dropped. That is documented.
It was the wrong default for a log scanner, and there is no per-record
`onError` on the stream.

The stream therefore still throws `FormatException`. Records already yielded
stay yielded, and the caller decides whether terminating the scan is
acceptable.

---

The original log did not itself request symbols. It recorded where a real
scan was longer to write than its selected JSON pointers. Version 1.6.0 added
only the three entries justified above and left the remaining design boundaries
explicit.
