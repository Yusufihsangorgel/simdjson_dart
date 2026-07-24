# simdjson_dart example

`simdjson_dart_example.dart` runs the scenario the package is built for: pulling
a few fields out of a large JSON payload without turning the whole thing into
Dart objects. It builds a 3 MB paginated response of 50,000 items, reads only
the header and the first record with `SimdJsonDocument.at`, then contrasts that
with a full `jsonDecode`-compatible decode and with how invalid input is
rejected.

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
rejected bad input: TAPE_ERROR: The JSON document has an improper structure
```

`at` walks arrays from the front, so selective access wins near the top of the
document (a header, the first records); reach for the full decode when you need
most of it. The speedup for selective access is measured at 5–14x over a full
decode in the package README's benchmark.
