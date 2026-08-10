// `at` returns null for two different facts. `exists` separates them.
//
// The ambiguity was found by reading how zikzak_json 0.2.2 -- the one package
// on pub.dev that depends on this one -- uses `at`. Its adapter fills a map
// with `result[path] = doc.at(pointer)`, so an absent key and an explicit null
// arrive at its callers as the same entry.
import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

void main() {
  group('exists', () {
    late SimdJsonDocument doc;

    setUp(() {
      doc = SimdJsonDocument.parse(
        '{"nickname": null, "name": "ada", "tags": [], "zero": 0, '
        '"blank": "", "no": false, "nested": {"deep": null}, '
        '"list": [null, 1]}',
      );
    });

    tearDown(() => doc.close());

    test('separates an explicit null from an absent key', () {
      // The pair that motivated the method: `at` cannot tell these apart.
      expect(doc.at('/nickname'), isNull);
      expect(doc.at('/missing'), isNull);

      expect(doc.exists('/nickname'), isTrue);
      expect(doc.exists('/missing'), isFalse);
    });

    test('is true for the falsy values that are not absence', () {
      // Empty, zero, false and "" are values. Only absence is absence.
      for (final pointer in ['/tags', '/zero', '/blank', '/no']) {
        expect(doc.exists(pointer), isTrue, reason: pointer);
      }
    });

    test('finds a null nested in an object and in an array', () {
      expect(doc.exists('/nested/deep'), isTrue);
      expect(doc.at('/nested/deep'), isNull);
      expect(doc.exists('/list/0'), isTrue);
      expect(doc.at('/list/0'), isNull);
    });

    test('is false for the ways a path can fail to resolve', () {
      expect(doc.exists('/list/9'), isFalse, reason: 'index out of bounds');
      expect(doc.exists('/name/nope'), isFalse, reason: 'scalar mid-path');
      expect(doc.exists('/nested/deep/deeper'), isFalse, reason: 'past a null');
    });

    test('the whole document exists', () {
      expect(doc.exists(''), isTrue);
    });

    test('agrees with at on every hit', () {
      // Anything at() materialises must be something exists() confirms;
      // the two must not disagree about what is in the document.
      for (final pointer in ['/name', '/tags', '/zero', '/nested']) {
        expect(doc.at(pointer), isNotNull, reason: pointer);
        expect(doc.exists(pointer), isTrue, reason: pointer);
      }
    });

    test('rejects a malformed pointer the same way at does', () {
      // Same precondition as at(), so a pointer exists() accepts is one at()
      // will accept -- callers can use them in either order.
      expect(() => doc.exists('no-leading-slash'), throwsFormatException);
      expect(() => doc.at('no-leading-slash'), throwsFormatException);
    });

    test('throws once the document is closed', () {
      final closed = SimdJsonDocument.parse('{"a": 1}')..close();
      expect(() => closed.exists('/a'), throwsStateError);
    });
  });
}
