import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:test/test.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

Stream<List<int>> _chunks(String value, int size) async* {
  final bytes = _bytes(value);
  for (var start = 0; start < bytes.length; start += size) {
    final end = start + size < bytes.length ? start + size : bytes.length;
    yield bytes.sublist(start, end);
  }
}

void main() {
  test('selects values and preserves explicit null versus missing', () async {
    final rows = await simdJsonSelectNdjsonStream(
      Stream<List<int>>.fromIterable([
        _bytes('{"name":"first","nil":null}\n{"name":"second"}\n'),
      ]),
      ['/name', '/nil', '/missing'],
    ).toList();

    expect(rows, [
      {'/name': 'first', '/nil': null},
      {'/name': 'second'},
    ]);
    expect(rows.first.containsKey('/nil'), isTrue);
    expect(rows.first.containsKey('/missing'), isFalse);
    expect(rows.last.containsKey('/nil'), isFalse);
  });

  test('checks existence without materializing subtrees', () async {
    final rows = await simdJsonSelectNdjsonStream(
      Stream<List<int>>.value(
        _bytes(
          '{"org":{"id":1},"nil":null,"existenceNull":null,'
          '"overlap":{"body":"kept"},'
          '"payload":{"pull_request":{"body":"unused"}}}\n',
        ),
      ),
      ['/nil', '/overlap'],
      existencePointers: [
        '/org',
        '/payload/pull_request',
        '/existenceNull',
        '/nil',
        '/overlap',
        '/missing',
      ],
    ).toList();

    expect(rows, [
      {
        '/nil': null,
        '/overlap': {'body': 'kept'},
        '/org': true,
        '/payload/pull_request': true,
        '/existenceNull': true,
      },
    ]);
    expect(rows.single.containsKey('/missing'), isFalse);
  });

  test('snapshots pointer iterables once when listening starts', () async {
    var valueIterations = 0;
    var existenceIterations = 0;

    Iterable<String> values() sync* {
      valueIterations++;
      yield '/value';
    }

    Iterable<String> existence() sync* {
      existenceIterations++;
      yield '/present';
    }

    final stream = simdJsonSelectNdjsonStream(
      Stream<List<int>>.value(
        _bytes('{"value":1,"present":{}}\n{"value":2,"present":[]}\n'),
      ),
      values(),
      existencePointers: existence(),
    );
    expect(valueIterations, 0);
    expect(existenceIterations, 0);

    expect(await stream.toList(), [
      {'/value': 1, '/present': true},
      {'/value': 2, '/present': true},
    ]);
    expect(valueIterations, 1);
    expect(existenceIterations, 1);
  });

  test('carries UTF-8 and lines across every one-byte chunk', () async {
    const input =
        '\u{feff}{"city":"İstanbul","emoji":"🍰","nil":null}\r\n'
        ' \t\r\n'
        '{"city":"İzmir"}';

    final rows = await simdJsonSelectNdjsonStream(_chunks(input, 1), [
      '/city',
      '/emoji',
      '/nil',
    ]).toList();

    expect(rows, [
      {'/city': 'İstanbul', '/emoji': '🍰', '/nil': null},
      {'/city': 'İzmir'},
    ]);
  });

  test('selected Dart values survive later documents and stream end', () async {
    final rows = await simdJsonSelectNdjsonStream(
      _chunks(
        '{"nested":{"items":[1,2]},"unused":"first"}\n'
        '{"nested":{"items":[3]},"unused":"second"}\n',
        7,
      ),
      ['/nested'],
    ).toList();

    expect(rows.first, {
      '/nested': {
        'items': [1, 2],
      },
    });
    expect(rows.last, {
      '/nested': {
        'items': [3],
      },
    });
  });

  test(
    'cancelling after one row does not parse later rows in the chunk',
    () async {
      final rows = await simdJsonSelectNdjsonStream(
        Stream<List<int>>.value(_bytes('{"ok":1}\n{"broken":\n')),
        ['/ok'],
      ).take(1).toList();

      expect(rows, [
        {'/ok': 1},
      ]);
    },
  );

  test('empty pointer selects the complete record', () async {
    final rows = await simdJsonSelectNdjsonStream(
      Stream<List<int>>.value(_bytes('[1,{"ok":true}]\n')),
      [''],
    ).toList();

    expect(rows, [
      {
        '': [
          1,
          {'ok': true},
        ],
      },
    ]);
  });

  test('blank input yields nothing', () async {
    expect(
      await simdJsonSelectNdjsonStream(_chunks(' \n\t\r\n', 1), [
        '/value',
      ]).toList(),
      isEmpty,
    );
  });

  test('a malformed line stops after earlier selected rows', () async {
    await expectLater(
      simdJsonSelectNdjsonStream(
        Stream<List<int>>.fromIterable([
          _bytes('{"ok":1}\n'),
          _bytes('{"broken":\n{"ok":2}\n'),
        ]),
        ['/ok'],
      ),
      emitsInOrder([
        {'/ok': 1},
        emitsError(isA<FormatException>()),
      ]),
    );
  });

  test('a malformed pointer is reported by the document boundary', () async {
    await expectLater(
      simdJsonSelectNdjsonStream(
        Stream<List<int>>.value(_bytes('{"ok":1}\n')),
        ['ok'],
      ),
      emitsError(isA<FormatException>()),
    );
  });

  test('number range errors do not fall back to a full decode', () async {
    await expectLater(
      simdJsonSelectNdjsonStream(
        Stream<List<int>>.value(_bytes('{"value":18446744073709551616}\n')),
        ['/value'],
      ),
      emitsError(isA<FormatException>()),
    );
  });

  group('simdJsonSelectNdjsonFile', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('simdjson_select_file');
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    test('selects from one-byte file chunks', () async {
      final file = File('${directory.path}/rows.jsonl')
        ..writeAsStringSync(
          '{"name":"İstanbul","org":{"id":1}}\n'
          '{"name":"İzmir"}',
        );

      expect(
        await simdJsonSelectNdjsonFile(
          file.path,
          ['/name'],
          existencePointers: ['/org'],
          chunkSize: 1,
        ).toList(),
        [
          {'/name': 'İstanbul', '/org': true},
          {'/name': 'İzmir'},
        ],
      );
    });

    test('reports a missing file lazily with IO_ERROR', () async {
      final stream = simdJsonSelectNdjsonFile(
        '${directory.path}/missing.jsonl',
        ['/name'],
      );

      await expectLater(
        stream,
        emitsError(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('IO_ERROR'),
          ),
        ),
      );
    });

    test('validates chunkSize synchronously', () {
      expect(
        () => simdJsonSelectNdjsonFile('${directory.path}/rows.jsonl', [
          '/name',
        ], chunkSize: 0),
        throwsArgumentError,
      );
    });
  });
}
