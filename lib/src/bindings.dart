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

/// Allocates [size] bytes of native memory, or returns null on failure.
@Native<Pointer<Uint8> Function(Uint64)>(symbol: 'sj_alloc')
external Pointer<Uint8> sjAlloc(int size);

/// Releases a block from [sjAlloc] or a result tape.
@Native<Void Function(Pointer<Uint8>)>(symbol: 'sj_free')
external void sjFree(Pointer<Uint8> block);

/// Turns the counts behind [sjLiveAllocations] and [sjPeakBytes] on or off
/// for the whole process. They are off by default, and only tests turn them
/// on.
@Native<Void Function(Bool)>(symbol: 'sj_count_allocations')
external void sjCountAllocations(bool on);

/// Blocks from [sjAlloc], result tapes, and open documents taken while
/// counting was on and not yet released, across the whole process.
@Native<Int64 Function()>(symbol: 'sj_live_allocations')
external int sjLiveAllocations();

/// The most bytes of counted [sjAlloc] blocks and result tapes held at once
/// since the last [sjResetPeakBytes].
@Native<Uint64 Function()>(symbol: 'sj_peak_bytes')
external int sjPeakBytes();

/// Starts a new [sjPeakBytes] measurement from the bytes held now.
@Native<Void Function()>(symbol: 'sj_reset_peak_bytes')
external void sjResetPeakBytes();

@Native<Pointer<Void> Function(Pointer<Uint8>, Uint64, Pointer<SjResult>)>(
  symbol: 'sj_open',
)
external Pointer<Void> sjOpen(
  Pointer<Uint8> json,
  int length,
  Pointer<SjResult> result,
);

@Native<Pointer<Void> Function(Pointer<Uint8>, Uint64, Pointer<SjResult>)>(
  symbol: 'sj_open_file',
)
external Pointer<Void> sjOpenFile(
  Pointer<Uint8> path,
  int pathLength,
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

/// Resolves a mode-tagged, length-and-offset encoded JSON pointer batch.
@Native<
  Void Function(Pointer<Void>, Pointer<Uint8>, Uint64, Pointer<SjResult>)
>(symbol: 'sj_at_many')
external void sjAtMany(
  Pointer<Void> handle,
  Pointer<Uint8> pointers,
  int pointersLength,
  Pointer<SjResult> result,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'sj_close')
external void sjClose(Pointer<Void> handle);
