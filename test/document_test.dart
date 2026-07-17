import 'dart:convert';

import 'package:simdjson/simdjson.dart';
import 'package:test/test.dart';

void main() {
  const json = '''
  {
    "meta": {"total": 3, "cursor": null},
    "items": [
      {"id": 1, "name": "first", "price": 9.5},
      {"id": 2, "name": "with/slash~key", "tags": ["a", "b"]},
      {"id": 3, "name": "üçüncü"}
    ]
  }
  ''';

  test('reads scalar values by JSON pointer', () {
    final doc = SimdJsonDocument.parse(json);
    addTearDown(doc.close);
    expect(doc.at('/meta/total'), 3);
    expect(doc.at('/meta/cursor'), isNull);
    expect(doc.at('/items/0/name'), 'first');
    expect(doc.at('/items/0/price'), 9.5);
    expect(doc.at('/items/2/name'), 'üçüncü');
  });

  test('materializes subtrees', () {
    final doc = SimdJsonDocument.parse(json);
    addTearDown(doc.close);
    expect(doc.at('/items/1/tags'), ['a', 'b']);
    expect(doc.at('/meta'), {'total': 3, 'cursor': null});
  });

  test('empty pointer returns the whole document', () {
    final doc = SimdJsonDocument.parse(json);
    addTearDown(doc.close);
    expect(doc.at(''), jsonDecode(json));
  });

  test('missing paths return null', () {
    final doc = SimdJsonDocument.parse(json);
    addTearDown(doc.close);
    expect(doc.at('/nope'), isNull);
    expect(doc.at('/items/99'), isNull);
    expect(doc.at('/meta/total/deeper'), isNull);
  });

  test('escaped pointer tokens work (RFC 6901)', () {
    final doc = SimdJsonDocument.parse('{"a/b": {"c~d": 42}}');
    addTearDown(doc.close);
    expect(doc.at('/a~1b/c~0d'), 42);
  });

  test('invalid JSON throws FormatException', () {
    expect(() => SimdJsonDocument.parse('{nope'), throwsFormatException);
  });

  test('use after close throws StateError', () {
    final doc = SimdJsonDocument.parse(json);
    doc.close();
    expect(doc.isClosed, isTrue);
    expect(() => doc.at('/meta'), throwsStateError);
    // Second close is a no-op.
    doc.close();
  });

  test('many documents open and close cleanly', () {
    for (var i = 0; i < 500; i++) {
      final doc = SimdJsonDocument.parse('{"i": $i}');
      expect(doc.at('/i'), i);
      doc.close();
    }
  });
}
