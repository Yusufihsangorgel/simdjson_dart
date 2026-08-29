/// Fast JSON decoding for Dart using the simdjson C++ library over FFI.
///
/// [simdJsonDecode] is a drop-in alternative to `jsonDecode`; use
/// [simdJsonDecodeBytes] when the input is already UTF-8 bytes,
/// [simdJsonDecodeNdjsonStream] / [simdJsonDecodeNdjsonFile] for NDJSON
/// that does not fit in memory, and [SimdJsonDocument] to read selected
/// fields out of large documents without materializing the rest.
library;

export 'src/decoder.dart'
    show
        simdJsonDecode,
        simdJsonDecodeBytes,
        simdJsonDecodeNdjson,
        simdJsonDecodeNdjsonBytes;
export 'src/document.dart' show SimdJsonDocument;
export 'src/ndjson_stream.dart'
    show simdJsonDecodeNdjsonFile, simdJsonDecodeNdjsonStream;
