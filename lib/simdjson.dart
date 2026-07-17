/// Fast JSON decoding for Dart using the simdjson C++ library over FFI.
///
/// [simdJsonDecode] is a drop-in alternative to `jsonDecode`; use
/// [simdJsonDecodeBytes] when the input is already UTF-8 bytes, and
/// [SimdJsonDocument] to read selected fields out of large documents
/// without materializing the rest.
library;

export 'src/decoder.dart' show simdJsonDecode, simdJsonDecodeBytes;
export 'src/document.dart' show SimdJsonDocument;
