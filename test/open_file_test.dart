import 'dart:io';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('simdjson_file'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, String contents) =>
      File('${dir.path}/$name')..writeAsStringSync(contents);

  group('SimdJsonDocument.openFile', () {
    test('reads selected fields out of a file', () {
      final file = write(
        'doc.json',
        '{"meta":{"total":3,"tag":"x"},"items":[{"name":"a"},{"name":"b"}]}',
      );
      final doc = SimdJsonDocument.openFile(file.path);
      addTearDown(doc.close);

      expect(doc.at('/meta/total'), 3);
      expect(doc.at('/meta/tag'), 'x');
      expect(doc.at('/items/1/name'), 'b');
      expect(doc.at('/meta/missing'), isNull);
    });

    test('agrees with parseBytes on the same file', () {
      final json = '{"a":[1,2,{"b":"c"}],"d":{"e":null,"f":1.5}}';
      final file = write('same.json', json);
      final fromFile = SimdJsonDocument.openFile(file.path);
      final fromBytes = SimdJsonDocument.parseBytes(file.readAsBytesSync());
      addTearDown(fromFile.close);
      addTearDown(fromBytes.close);

      for (final pointer in ['', '/a', '/a/2/b', '/d', '/d/e', '/d/f']) {
        expect(
          fromFile.at(pointer),
          fromBytes.at(pointer),
          reason: 'pointer "$pointer"',
        );
      }
    });

    test('tells a missing file apart from a malformed one', () {
      // Both fail, and the caller has to be able to act on which: one is a
      // path to fix, the other is data to fix.
      expect(
        () => SimdJsonDocument.openFile('${dir.path}/absent.json'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('IO_ERROR'),
          ),
        ),
      );
      final bad = write('bad.json', '{"a":');
      expect(
        () => SimdJsonDocument.openFile(bad.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            isNot(contains('IO_ERROR')),
          ),
        ),
      );
    });

    test('handles a non-ASCII path', () {
      final file = write('ölçüm-测试.json', '{"ok":true}');
      final doc = SimdJsonDocument.openFile(file.path);
      addTearDown(doc.close);
      expect(doc.at('/ok'), true);
    });

    test('an empty file fails rather than reading as null', () {
      final empty = write('empty.json', '');
      expect(
        () => SimdJsonDocument.openFile(empty.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('reaches deep into a file too large to want in memory', () {
      // The entry exists for files big enough that materializing them to read
      // a couple of fields is the dominant cost, so the size it is meant for
      // is the size it has to be exercised at.
      final payload = 'x' * 200;
      final buffer = StringBuffer('{"meta":{"total":20000},"items":[');
      for (var i = 0; i < 20000; i++) {
        if (i > 0) buffer.write(',');
        buffer.write('{"id":$i,"payload":"$payload"}');
      }
      buffer.write(']}');
      final file = write('big.json', buffer.toString());
      expect(file.lengthSync(), greaterThan(4 * 1024 * 1024));

      final doc = SimdJsonDocument.openFile(file.path);
      addTearDown(doc.close);
      expect(doc.at('/meta/total'), 20000);
      expect(doc.at('/items/0/id'), 0);
      expect(doc.at('/items/19999/id'), 19999);
      expect(doc.at('/items/20000/id'), isNull, reason: 'past the end');
    });
  });
}
