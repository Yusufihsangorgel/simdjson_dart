import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

void main() {
  group('SimdJsonDocument.atMany', () {
    late SimdJsonDocument document;

    setUp(() {
      document = SimdJsonDocument.parse(r'''
        {
          "a/b~c": {"items": [{"value": 7}]},
          "nested": {"array": [10, 20]},
          "scalar": 1,
          "nil": null,
          "nul\u0000key": "embedded"
        }
      ''');
    });

    tearDown(() => document.close());

    test('resolves distinct pointers together in first-seen order', () {
      const nulPointer = '/nul\u0000key';
      final values = document.atMany([
        '',
        '/a~1b~0c/items/0/value',
        '/nested/array/1',
        '/nil',
        '/missing',
        '/nested/array/99',
        '/scalar/deeper',
        nulPointer,
        '/nested/array/1',
      ]);

      expect(values.keys, [
        '',
        '/a~1b~0c/items/0/value',
        '/nested/array/1',
        '/nil',
        nulPointer,
      ]);
      expect(values[''], isA<Map<String, Object?>>());
      expect(values['/a~1b~0c/items/0/value'], 7);
      expect(values['/nested/array/1'], 20);
      expect(values['/nil'], isNull);
      expect(values.containsKey('/nil'), isTrue);
      expect(values.containsKey('/missing'), isFalse);
      expect(values.containsKey('/nested/array/99'), isFalse);
      expect(values.containsKey('/scalar/deeper'), isFalse);
      expect(values[nulPointer], 'embedded');
    });

    test('an empty iterable returns an empty map', () {
      expect(document.atMany(const []), isEmpty);
    });

    test('checks existence without materializing values', () {
      final values = document.atMany(
        ['/nested/array', '/nested/array'],
        existencePointers: [
          '/a~1b~0c',
          '/nil',
          '/missing',
          '/nested/array',
          '/a~1b~0c',
        ],
      );

      expect(values.keys, ['/nested/array', '/a~1b~0c', '/nil']);
      expect(values['/nested/array'], [10, 20]);
      expect(values['/a~1b~0c'], isTrue);
      expect(values['/nil'], isTrue);
      expect(values.containsKey('/missing'), isFalse);
    });

    test('rejects a malformed pointer', () {
      expect(
        () => document.atMany(['/nested/array/0', 'no-leading-slash']),
        throwsFormatException,
      );
    });

    test('rejects a malformed existence pointer', () {
      expect(
        () => document.atMany(
          ['/nested/array/0'],
          existencePointers: ['no-leading-slash'],
        ),
        throwsFormatException,
      );
    });

    test('throws after the document is closed', () {
      document.close();
      expect(() => document.atMany(['/nil']), throwsStateError);
    });

    test('throws if a lazy iterable closes the document', () {
      Iterable<String> closeWhileIterating() sync* {
        yield '/nil';
        document.close();
        yield '/nested/array/0';
      }

      expect(() => document.atMany(closeWhileIterating()), throwsStateError);
    });

    test('throws if a lazy existence iterable closes the document', () {
      Iterable<String> closeWhileIterating() sync* {
        yield '/nil';
        document.close();
        yield '/nested/array/0';
      }

      expect(
        () => document.atMany([
          '/nested/array/1',
        ], existencePointers: closeWhileIterating()),
        throwsStateError,
      );
    });
  });
}
