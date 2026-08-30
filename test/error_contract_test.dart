import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:simdjson_dart/simdjson_dart.dart';
import 'package:simdjson_dart/src/bindings.dart';
import 'package:simdjson_dart/src/decoder.dart';
import 'package:test/test.dart';

const _tapeError = 'TAPE_ERROR:';
const _utf8Error = 'UTF8_ERROR: The input is not valid UTF-8';
const _depthError =
    'DEPTH_ERROR: The JSON document was too deep (too many nested objects and arrays)';
const _stringError = 'STRING_ERROR: Problem while parsing a string';
const _bigIntError =
    'BIGINT_ERROR: Big integer value that cannot be represented using 64 bits';
const _numberError = 'NUMBER_ERROR: Problem while parsing a number';
const _invalidPointer = 'INVALID_JSON_POINTER: Invalid JSON pointer syntax.';
const _truncated = 'NDJSON input ends with an incomplete document';
const _ioError = 'IO_ERROR: Error reading the file.';
const _emptyError = 'EMPTY: no JSON found';
const _capacityError =
    "CAPACITY: This parser can't support a document that big";
const _invalidBatch = 'Invalid encoded JSON pointer batch';
const _closed = 'SimdJsonDocument has been closed';

TypeMatcher<FormatException> _formatWithMarker(String marker) =>
    isA<FormatException>().having(
      (error) => error.message,
      'message',
      startsWith(marker),
    );

TypeMatcher<FormatException> _formatWithExactMessage(String message) =>
    isA<FormatException>().having(
      (error) => error.message,
      'message',
      equals(message),
    );

TypeMatcher<FormatException> _formatWithDiagnostic() =>
    isA<FormatException>().having(
      (error) => error.message,
      'message',
      allOf(isNotEmpty, contains(':')),
    );

TypeMatcher<FormatException> _formatWithNumberRangeMessage() =>
    isA<FormatException>().having(
      (error) => error.message,
      'message',
      anyOf(_bigIntError, _numberError),
    );

TypeMatcher<FormatException> _formatWithMarkerAndSource(
  String marker,
  Object source,
) => _formatWithMarker(
  marker,
).having((error) => error.source, 'source', same(source));

TypeMatcher<FormatException> _formatWithMarkerAndBytes(
  String marker,
  List<int> source,
) => _formatWithMarker(
  marker,
).having((error) => error.source, 'source', orderedEquals(source));

TypeMatcher<FormatException> _formatWithExactMessageAndNullSource(
  String message,
) => _formatWithExactMessage(
  message,
).having((error) => error.source, 'source', isNull);

TypeMatcher<FormatException> _formatWithMarkerAndNullSource(String marker) =>
    _formatWithMarker(marker).having((error) => error.source, 'source', isNull);

TypeMatcher<StateError> _closedStateError() => isA<StateError>().having(
  (error) => error.message,
  'message',
  equals(_closed),
);

TypeMatcher<ArgumentError> _invalidChunkSize(int value) => isA<ArgumentError>()
    .having((error) => error.invalidValue, 'invalidValue', equals(value))
    .having((error) => error.name, 'name', equals('chunkSize'))
    .having((error) => error.message, 'message', equals('must be at least 1'));

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  test('resident decoders preserve native error type, marker, and source', () {
    const malformed = '{"a":}';
    expect(
      () => simdJsonDecode(malformed),
      throwsA(_formatWithMarker(_tapeError)),
    );

    final malformedBytes = _bytes(malformed);
    expect(
      () => simdJsonDecodeBytes(malformedBytes),
      throwsA(_formatWithMarkerAndSource(_tapeError, malformedBytes)),
    );

    final invalidUtf8 = Uint8List.fromList([0xff]);
    expect(
      () => simdJsonDecodeBytes(invalidUtf8),
      throwsA(
        _formatWithExactMessage(
          _utf8Error,
        ).having((error) => error.source, 'source', same(invalidUtf8)),
      ),
    );

    for (final strictInput in ['{"a":1,}', 'NaN']) {
      expect(
        () => simdJsonDecode(strictInput),
        throwsA(_formatWithDiagnostic()),
        reason: strictInput,
      );
    }

    expect(
      () => simdJsonDecode(r'"\ud800"'),
      throwsA(_formatWithExactMessage(_stringError)),
    );

    final deep =
        '${List.filled(1025, '[').join()}0${List.filled(1025, ']').join()}';
    expect(
      () => simdJsonDecode(deep),
      throwsA(_formatWithExactMessage(_depthError)),
    );

    final malformedNdjson = _bytes('{"ok":1}\n{"broken":1,}\n');
    expect(
      () => simdJsonDecodeNdjsonBytes(malformedNdjson),
      throwsA(_formatWithMarkerAndSource(_tapeError, malformedNdjson)),
    );

    final truncatedNdjson = _bytes('{"ok":1}\n{"a":');
    expect(
      () => simdJsonDecodeNdjsonBytes(truncatedNdjson),
      throwsA(
        _formatWithExactMessage(
          _truncated,
        ).having((error) => error.source, 'source', same(truncatedNdjson)),
      ),
    );

    final invalidUtf8Ndjson = Uint8List.fromList([0xff, 0x0a]);
    expect(
      () => simdJsonDecodeNdjsonBytes(invalidUtf8Ndjson),
      throwsA(
        _formatWithExactMessage(
          _utf8Error,
        ).having((error) => error.source, 'source', same(invalidUtf8Ndjson)),
      ),
    );
  });

  test(
    'documents retain strict native failures and free the parse boundary',
    () {
      expect(
        () => SimdJsonDocument.parse('{"v":18446744073709551616}'),
        throwsA(_formatWithNumberRangeMessage()),
      );

      final invalidUtf8 = Uint8List.fromList([0xff]);
      expect(
        () => SimdJsonDocument.parseBytes(invalidUtf8),
        throwsA(_formatWithExactMessage(_utf8Error)),
      );

      expect(
        () => SimdJsonDocument.parse(r'"\ud800"'),
        throwsA(_formatWithExactMessage(_stringError)),
      );

      final deep =
          '${List.filled(1025, '[').join()}0${List.filled(1025, ']').join()}';
      expect(
        () => SimdJsonDocument.parse(deep),
        throwsA(_formatWithExactMessage(_depthError)),
      );

      final document = SimdJsonDocument.parse('{"ok":true}');
      expect(document.at('/ok'), isTrue);
      document.close();
    },
  );

  test('at and exists pin malformed-pointer source and closed state', () {
    final document = SimdJsonDocument.parse('{"a":1}');
    const malformed = 'not-a-pointer';
    expect(
      () => document.at(malformed),
      throwsA(
        _formatWithExactMessage(
          _invalidPointer,
        ).having((error) => error.source, 'source', same(malformed)),
      ),
    );
    expect(
      () => document.exists(malformed),
      throwsA(
        _formatWithExactMessage(
          _invalidPointer,
        ).having((error) => error.source, 'source', same(malformed)),
      ),
    );

    document.close();
    expect(() => document.at('/a'), throwsA(_closedStateError()));
    expect(() => document.exists('/a'), throwsA(_closedStateError()));
  });

  test(
    'atMany pins malformed value/existence pointers and every close path',
    () {
      final malformedValue = SimdJsonDocument.parse('{"a":1}');
      expect(
        () => malformedValue.atMany(['/a', 'not-a-pointer']),
        throwsA(_formatWithExactMessageAndNullSource(_invalidPointer)),
      );
      malformedValue.close();

      final malformedExistence = SimdJsonDocument.parse('{"a":1}');
      expect(
        () => malformedExistence.atMany(
          ['/a'],
          existencePointers: ['not-a-pointer'],
        ),
        throwsA(_formatWithExactMessageAndNullSource(_invalidPointer)),
      );
      malformedExistence.close();

      final initiallyClosed = SimdJsonDocument.parse('{"a":1}')..close();
      expect(
        () => initiallyClosed.atMany(['/a']),
        throwsA(_closedStateError()),
      );

      final lazyValue = SimdJsonDocument.parse('{"a":1}');
      Iterable<String> closesDuringValues() sync* {
        yield '/a';
        lazyValue.close();
        yield '/a';
      }

      expect(
        () => lazyValue.atMany(closesDuringValues()),
        throwsA(_closedStateError()),
      );

      final lazyExistence = SimdJsonDocument.parse('{"a":1}');
      Iterable<String> closesDuringExistence() sync* {
        yield '/a';
        lazyExistence.close();
        yield '/a';
      }

      expect(
        () => lazyExistence.atMany(
          const [],
          existencePointers: closesDuringExistence(),
        ),
        throwsA(_closedStateError()),
      );

      final iterableError = StateError('pointer iterable failed');
      Iterable<String> failingPointers() sync* {
        throw iterableError;
      }

      final iterableDocument = SimdJsonDocument.parse('{"a":1}');
      addTearDown(iterableDocument.close);
      expect(
        () => iterableDocument.atMany(failingPointers()),
        throwsA(same(iterableError)),
      );
    },
  );

  test(
    'full NDJSON streams pin malformed, truncated, and source failures',
    () async {
      final malformed = _bytes('{"ok":1}\n{"broken":1,}\n');
      await expectLater(
        simdJsonDecodeNdjsonStream(Stream.value(malformed)).toList(),
        throwsA(_formatWithMarkerAndBytes(_tapeError, malformed)),
      );

      final truncated = _bytes('{"ok":1}\n{"a":');
      await expectLater(
        simdJsonDecodeNdjsonStream(Stream.value(truncated)).toList(),
        throwsA(
          _formatWithExactMessage(_truncated).having(
            (error) => error.source,
            'source',
            orderedEquals(_bytes('{"a":')),
          ),
        ),
      );

      final sourceError = StateError('source stream failed');
      await expectLater(
        simdJsonDecodeNdjsonStream(
          Stream<List<int>>.error(sourceError),
        ).toList(),
        throwsA(same(sourceError)),
      );
    },
  );

  test(
    'selective NDJSON streams pin pointer and number-range failures',
    () async {
      final malformed = _bytes('{"broken":\n');
      await expectLater(
        simdJsonSelectNdjsonStream(Stream.value(malformed), [
          '/broken',
        ]).toList(),
        throwsA(_formatWithMarker(_tapeError)),
      );

      final malformedValuePointer = _bytes('{"a":1}\n');
      await expectLater(
        simdJsonSelectNdjsonStream(Stream.value(malformedValuePointer), [
          'not-a-pointer',
        ]).toList(),
        throwsA(_formatWithExactMessageAndNullSource(_invalidPointer)),
      );

      final malformedExistencePointer = _bytes('{"a":1}\n');
      await expectLater(
        simdJsonSelectNdjsonStream(
          Stream.value(malformedExistencePointer),
          const [],
          existencePointers: ['not-a-pointer'],
        ).toList(),
        throwsA(_formatWithExactMessageAndNullSource(_invalidPointer)),
      );

      final numberRange = _bytes('{"value":18446744073709551616}\n');
      await expectLater(
        simdJsonSelectNdjsonStream(Stream.value(numberRange), [
          '/value',
        ]).toList(),
        throwsA(
          _formatWithNumberRangeMessage().having(
            (error) => error.source,
            'source',
            isNull,
          ),
        ),
      );

      final sourceError = StateError('select source failed');
      await expectLater(
        simdJsonSelectNdjsonStream(Stream<List<int>>.error(sourceError), const [
          '/value',
        ]).toList(),
        throwsA(same(sourceError)),
      );

      final iterableError = StateError('select pointer iterable failed');
      Iterable<String> failingPointers() sync* {
        throw iterableError;
      }

      await expectLater(
        simdJsonSelectNdjsonStream(
          Stream<List<int>>.value(_bytes('{"value":1}\n')),
          failingPointers(),
        ).toList(),
        throwsA(same(iterableError)),
      );
    },
  );

  test(
    'file APIs validate synchronously and preserve lazy IO/parse errors',
    () async {
      expect(
        () => simdJsonDecodeNdjsonFile('unused.jsonl', chunkSize: 0),
        throwsA(_invalidChunkSize(0)),
      );
      expect(
        () => simdJsonSelectNdjsonFile('unused.jsonl', const [
          '/a',
        ], chunkSize: -1),
        throwsA(_invalidChunkSize(-1)),
      );

      final directory = Directory.systemTemp.createTempSync('simdjson_errors');
      addTearDown(() => directory.deleteSync(recursive: true));
      final missing = '${directory.path}/missing.jsonl';

      final fullMissing = simdJsonDecodeNdjsonFile(missing);
      final selectiveMissing = simdJsonSelectNdjsonFile(missing, const ['/a']);
      await expectLater(
        fullMissing.toList(),
        throwsA(
          _formatWithExactMessage(
            _ioError,
          ).having((error) => error.source, 'source', equals(missing)),
        ),
      );
      await expectLater(
        selectiveMissing.toList(),
        throwsA(
          _formatWithExactMessage(
            _ioError,
          ).having((error) => error.source, 'source', equals(missing)),
        ),
      );

      expect(
        () => SimdJsonDocument.openFile(missing),
        throwsA(_formatWithExactMessage(_ioError)),
      );

      final emptyPath = '${directory.path}/empty.json';
      File(emptyPath).writeAsStringSync('');
      expect(
        () => SimdJsonDocument.openFile(emptyPath),
        throwsA(_formatWithExactMessage(_emptyError)),
      );

      final malformedPath = '${directory.path}/malformed.jsonl';
      File(malformedPath).writeAsStringSync('{"broken":');
      await expectLater(
        simdJsonDecodeNdjsonFile(malformedPath).toList(),
        throwsA(_formatWithExactMessage(_truncated)),
      );
      await expectLater(
        simdJsonSelectNdjsonFile(malformedPath, const ['/broken']).toList(),
        throwsA(_formatWithMarkerAndNullSource(_tapeError)),
      );
    },
  );

  test('internal allocation and tape corruption keep typed contracts', () {
    const maxInt = 0x7fffffffffffffff;
    try {
      final pointer = allocateBytes(maxInt);
      freeBytes(pointer);
      fail('allocateBytes($maxInt) unexpectedly succeeded');
    } on StateError catch (error) {
      expect(error.message, 'native allocation of $maxInt bytes failed');
    }

    expect(
      () => decodeTape(Uint8List.fromList([0xff])),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          equals('corrupt tape: unknown tag 255 at 0'),
        ),
      ),
    );

    final oversizedInput = allocateBytes(64);
    final oversizedResult = allocateResult();
    try {
      oversizedInput.asTypedList(64).fillRange(0, 64, 0);
      sjParse(oversizedInput, 0x100000000, oversizedResult);
      expect(oversizedResult.ref.errorCode, isNonZero);
      expect(errorMessageOf(oversizedResult.ref), _capacityError);
      expect(oversizedResult.ref.tape, nullptr);
    } finally {
      freeResult(oversizedResult);
      freeBytes(oversizedInput);
    }

    final json = _bytes('{"a":1}');
    final padded = allocateBytes(json.length + 64);
    final openResult = allocateResult();
    padded.asTypedList(json.length + 64)
      ..setAll(0, json)
      ..fillRange(json.length, json.length + 64, 0);
    final handle = sjOpen(padded, json.length, openResult);
    try {
      expect(handle, isNot(nullptr));

      void expectInvalidBatch(Uint8List batch) {
        final nativeBatch = allocateBytes(batch.length);
        final batchResult = allocateResult();
        try {
          nativeBatch.asTypedList(batch.length).setAll(0, batch);
          sjAtMany(handle, nativeBatch, batch.length, batchResult);
          expect(batchResult.ref.errorCode, isNonZero);
          expect(errorMessageOf(batchResult.ref), _invalidBatch);
          expect(batchResult.ref.tape, nullptr);
        } finally {
          freeResult(batchResult);
          freeBytes(nativeBatch);
        }
      }

      expectInvalidBatch(Uint8List(1));

      final impossibleCount = Uint8List(8);
      ByteData.sublistView(impossibleCount).setUint64(0, 1, Endian.little);
      expectInvalidBatch(impossibleCount);

      Uint8List entryBatch({
        required int pointerOffset,
        required int pointerLength,
        required int mode,
      }) {
        final batch = Uint8List(32);
        ByteData.sublistView(batch)
          ..setUint64(0, 1, Endian.little)
          ..setUint64(8, pointerOffset, Endian.little)
          ..setUint64(16, pointerLength, Endian.little)
          ..setUint64(24, mode, Endian.little);
        return batch;
      }

      expectInvalidBatch(
        entryBatch(pointerOffset: 31, pointerLength: 0, mode: 0),
      );
      expectInvalidBatch(
        entryBatch(pointerOffset: 32, pointerLength: 1, mode: 0),
      );
      expectInvalidBatch(
        entryBatch(pointerOffset: 32, pointerLength: 0x100000000, mode: 0),
      );
      expectInvalidBatch(
        entryBatch(pointerOffset: 32, pointerLength: 0, mode: 2),
      );
    } finally {
      if (handle != nullptr) sjClose(handle);
      freeResult(openResult);
      freeBytes(padded);
    }
  });
}
