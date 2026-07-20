import 'dart:ffi';

/// Result struct of `sj_parse`; see src/simdjson_shim.cpp.
final class SjResult extends Struct {
  @Int32()
  external int errorCode;

  external Pointer<Utf8Char> errorMessage;

  external Pointer<Uint8> tape;

  @Uint64()
  external int tapeLength;
}

/// `char` on the C side; bytes of a NUL-terminated UTF-8 string.
typedef Utf8Char = Uint8;

@Native<Void Function(Pointer<Uint8>, Uint64, Pointer<SjResult>)>(
  symbol: 'sj_parse',
)
external void sjParse(
  Pointer<Uint8> json,
  int length,
  Pointer<SjResult> result,
);

/// Parses newline-delimited JSON. The tape is a u32 document count followed
/// by that many values in the [sjParse] format.
@Native<Void Function(Pointer<Uint8>, Uint64, Pointer<SjResult>)>(
  symbol: 'sj_parse_ndjson',
)
external void sjParseNdjson(
  Pointer<Uint8> json,
  int length,
  Pointer<SjResult> result,
);

@Native<Void Function(Pointer<Uint8>)>(symbol: 'sj_free')
external void sjFree(Pointer<Uint8> tape);

@Native<Pointer<Void> Function(Pointer<Uint8>, Uint64, Pointer<SjResult>)>(
  symbol: 'sj_open',
)
external Pointer<Void> sjOpen(
  Pointer<Uint8> json,
  int length,
  Pointer<SjResult> result,
);

@Native<
  Void Function(Pointer<Void>, Pointer<Uint8>, Uint64, Pointer<SjResult>)
>(symbol: 'sj_at')
external void sjAt(
  Pointer<Void> handle,
  Pointer<Uint8> pointer,
  int pointerLength,
  Pointer<SjResult> result,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'sj_close')
external void sjClose(Pointer<Void> handle);
