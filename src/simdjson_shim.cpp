// C ABI shim over simdjson: parses JSON and serializes the DOM into a
// compact tape the Dart side decodes in a single pass. One FFI call per
// document keeps the boundary cost constant instead of per-node.
//
// Tape format (little-endian):
//   0x00 null
//   0x01 true
//   0x02 false
//   0x03 int64            (8 bytes)
//   0x04 double           (8 bytes IEEE-754)
//   0x05 string           (u32 byte length + UTF-8 bytes)
//   0x06 array            (u32 element count, then elements)
//   0x07 object           (u32 pair count, then key string bytes + value)
//   Object keys are written as u32 length + bytes, with no leading tag.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <vector>

// MSVC exports nothing from a DLL by default; ELF/Mach-O may be built with
// hidden visibility. Mark the C ABI entry points exported explicitly.
#if defined(_WIN32)
#define SJ_EXPORT __declspec(dllexport)
#else
#define SJ_EXPORT __attribute__((visibility("default")))
#endif

#include "third_party/simdjson/simdjson.h"

namespace {

class TapeWriter {
 public:
  void u8(uint8_t v) { bytes_.push_back(v); }

  void u32(uint32_t v) {
    const size_t at = bytes_.size();
    bytes_.resize(at + 4);
    std::memcpy(bytes_.data() + at, &v, 4);
  }

  void raw(const void* data, size_t length) {
    const size_t at = bytes_.size();
    bytes_.resize(at + length);
    std::memcpy(bytes_.data() + at, data, length);
  }

  // For counts that are only known after iterating: reserves space now,
  // patched via patch_u32 later.
  size_t reserve_u32() {
    const size_t at = bytes_.size();
    bytes_.resize(at + 4);
    return at;
  }

  void patch_u32(size_t at, uint32_t v) {
    std::memcpy(bytes_.data() + at, &v, 4);
  }

  // Transfers ownership of the buffer to a malloc'd block.
  uint8_t* release(size_t* out_length) {
    *out_length = bytes_.size();
    auto* out = static_cast<uint8_t*>(std::malloc(bytes_.size()));
    if (out != nullptr) {
      std::memcpy(out, bytes_.data(), bytes_.size());
    }
    return out;
  }

 private:
  std::vector<uint8_t> bytes_;
};

simdjson::error_code write_element(const simdjson::dom::element& element,
                                   TapeWriter& tape) {
  switch (element.type()) {
    case simdjson::dom::element_type::NULL_VALUE:
      tape.u8(0x00);
      return simdjson::SUCCESS;
    case simdjson::dom::element_type::BOOL: {
      bool value;
      auto error = element.get(value);
      if (error) return error;
      tape.u8(value ? 0x01 : 0x02);
      return simdjson::SUCCESS;
    }
    case simdjson::dom::element_type::BIGINT:
      // simdjson 3.x added BIGINT for integers that exceed the 64-bit
      // range.  Fall through to the existing numeric paths, which coerce
      // oversized values to double — consistent with dart:convert's
      // jsonDecode behaviour.  If strict precision for huge integers is
      // needed, a BigInt.parse(string) callback would have to be routed
      // from here in a follow-up.
    case simdjson::dom::element_type::INT64: {
      int64_t value;
      auto error = element.get(value);
      if (error) return error;
      tape.u8(0x03);
      tape.raw(&value, 8);
      return simdjson::SUCCESS;
    }
    case simdjson::dom::element_type::UINT64: {
      // Values above int64 range only exist in JSON produced for 64-bit
      // unsigned integers; Dart ints are signed 64-bit, so surface these
      // as doubles the way dart:convert would parse them.
      uint64_t value;
      auto error = element.get(value);
      if (error) return error;
      if (value <= static_cast<uint64_t>(INT64_MAX)) {
        const int64_t as_signed = static_cast<int64_t>(value);
        tape.u8(0x03);
        tape.raw(&as_signed, 8);
      } else {
        const double as_double = static_cast<double>(value);
        tape.u8(0x04);
        tape.raw(&as_double, 8);
      }
      return simdjson::SUCCESS;
    }
    case simdjson::dom::element_type::DOUBLE: {
      double value;
      auto error = element.get(value);
      if (error) return error;
      tape.u8(0x04);
      tape.raw(&value, 8);
      return simdjson::SUCCESS;
    }
    case simdjson::dom::element_type::STRING: {
      std::string_view value;
      auto error = element.get(value);
      if (error) return error;
      tape.u8(0x05);
      tape.u32(static_cast<uint32_t>(value.size()));
      tape.raw(value.data(), value.size());
      return simdjson::SUCCESS;
    }
    case simdjson::dom::element_type::ARRAY: {
      simdjson::dom::array array;
      auto error = element.get(array);
      if (error) return error;
      tape.u8(0x06);
      // dom::array::size() saturates at 0xFFFFFF; count while iterating
      // instead. The 4 GB document cap keeps the count within u32.
      const size_t count_at = tape.reserve_u32();
      uint32_t count = 0;
      for (auto child : array) {
        auto child_error = write_element(child, tape);
        if (child_error) return child_error;
        ++count;
      }
      tape.patch_u32(count_at, count);
      return simdjson::SUCCESS;
    }
    case simdjson::dom::element_type::OBJECT: {
      simdjson::dom::object object;
      auto error = element.get(object);
      if (error) return error;
      tape.u8(0x07);
      const size_t count_at = tape.reserve_u32();
      uint32_t count = 0;
      for (auto field : object) {
        const std::string_view key = field.key;
        tape.u32(static_cast<uint32_t>(key.size()));
        tape.raw(key.data(), key.size());
        auto child_error = write_element(field.value, tape);
        if (child_error) return child_error;
        ++count;
      }
      tape.patch_u32(count_at, count);
      return simdjson::SUCCESS;
    }
  }
  return simdjson::UNEXPECTED_ERROR;
}

}  // namespace

extern "C" {

// Result of sj_parse. When error_code is 0, tape/tape_length hold a
// malloc'd buffer the caller must release with sj_free. When non-zero,
// error_message points to a static string (do not free).
struct SjResult {
  int32_t error_code;
  const char* error_message;
  uint8_t* tape;
  uint64_t tape_length;
};

// No C++ exception may cross the FFI boundary; every entry point catches
// everything (in practice only std::bad_alloc) and reports MEMALLOC.
void fail_alloc(SjResult* result) {
  if (result->tape != nullptr) {
    std::free(result->tape);
    result->tape = nullptr;
    result->tape_length = 0;
  }
  result->error_code = static_cast<int32_t>(simdjson::MEMALLOC);
  result->error_message = simdjson::error_message(simdjson::MEMALLOC);
}

SJ_EXPORT void sj_parse(const uint8_t* json, uint64_t length, SjResult* result) {
  result->error_code = 0;
  result->error_message = nullptr;
  result->tape = nullptr;
  result->tape_length = 0;

  try {
    static thread_local simdjson::dom::parser parser;
    simdjson::dom::element root;
    // The Dart side already provides SIMDJSON_PADDING bytes, so skip the
    // parser's internal defensive copy (realloc_if_needed = false).
    const auto error =
        parser.parse(reinterpret_cast<const char*>(json), length, false)
            .get(root);
    if (error) {
      result->error_code = static_cast<int32_t>(error);
      result->error_message = simdjson::error_message(error);
      return;
    }

    TapeWriter tape;
    const auto write_error = write_element(root, tape);
    if (write_error) {
      result->error_code = static_cast<int32_t>(write_error);
      result->error_message = simdjson::error_message(write_error);
      return;
    }

    size_t tape_length = 0;
    result->tape = tape.release(&tape_length);
    result->tape_length = tape_length;
    if (result->tape == nullptr) {
      fail_alloc(result);
    }
  } catch (...) {
    fail_alloc(result);
  }
}

// Parses newline-delimited JSON (one document per line, the shape log and
// data pipelines ship). The tape is a u32 document count followed by each
// document's value in exactly the format sj_parse produces, so the Dart
// reader decodes the count and then reads that many values.
SJ_EXPORT void sj_parse_ndjson(const uint8_t* json, uint64_t length,
                               SjResult* result) {
  result->error_code = 0;
  result->error_message = nullptr;
  result->tape = nullptr;
  result->tape_length = 0;

  try {
    static thread_local simdjson::dom::parser parser;
    simdjson::dom::document_stream stream;
    // As in sj_parse, the Dart side already provides SIMDJSON_PADDING bytes
    // past `length`, so the stream can read ahead safely.
    // The two-argument overload is deleted upstream to stop callers passing a
    // length where a batch size is expected, so name the batch size too.
    const auto open_error =
        parser
            .parse_many(reinterpret_cast<const char*>(json), length,
                        simdjson::dom::DEFAULT_BATCH_SIZE)
            .get(stream);
    if (open_error) {
      result->error_code = static_cast<int32_t>(open_error);
      result->error_message = simdjson::error_message(open_error);
      return;
    }

    TapeWriter tape;
    // Count is only known after the stream is drained; reserve and patch.
    const size_t count_at = tape.reserve_u32();
    uint32_t count = 0;
    for (auto document : stream) {
      simdjson::dom::element element;
      const auto document_error = document.get(element);
      if (document_error) {
        result->error_code = static_cast<int32_t>(document_error);
        result->error_message = simdjson::error_message(document_error);
        return;
      }
      const auto write_error = write_element(element, tape);
      if (write_error) {
        result->error_code = static_cast<int32_t>(write_error);
        result->error_message = simdjson::error_message(write_error);
        return;
      }
      count++;
    }

    // A document_stream treats trailing bytes that do not yet form a complete
    // document as "maybe completed by the next batch" and drops them. For a
    // whole-buffer parse that is silent data loss: the last line of a
    // truncated log would just disappear. Report it instead.
    if (stream.truncated_bytes() > 0) {
      static const char kTruncated[] =
          "NDJSON input ends with an incomplete document";
      result->error_code = static_cast<int32_t>(simdjson::TAPE_ERROR);
      result->error_message = kTruncated;
      return;
    }
    tape.patch_u32(count_at, count);

    size_t tape_length = 0;
    result->tape = tape.release(&tape_length);
    result->tape_length = tape_length;
    if (result->tape == nullptr) {
      fail_alloc(result);
    }
  } catch (...) {
    fail_alloc(result);
  }
}

SJ_EXPORT void sj_free(uint8_t* tape) { std::free(tape); }

// A parsed document held open for lazy, repeated access. The parser owns
// the underlying tape, so it lives alongside the root element.
struct SjDocument {
  simdjson::dom::parser parser;
  simdjson::dom::element root;
};

// Parses and keeps the document open. Returns null on error, with the
// details in `result`.
SJ_EXPORT void* sj_open(const uint8_t* json, uint64_t length, SjResult* result) {
  result->error_code = 0;
  result->error_message = nullptr;
  result->tape = nullptr;
  result->tape_length = 0;

  auto* document = new (std::nothrow) SjDocument();
  if (document == nullptr) {
    fail_alloc(result);
    return nullptr;
  }
  try {
    const auto error =
        document->parser
            .parse(reinterpret_cast<const char*>(json), length, false)
            .get(document->root);
    if (error) {
      result->error_code = static_cast<int32_t>(error);
      result->error_message = simdjson::error_message(error);
      delete document;
      return nullptr;
    }
    return document;
  } catch (...) {
    delete document;
    fail_alloc(result);
    return nullptr;
  }
}

// Resolves a JSON Pointer (RFC 6901) inside an open document and
// serializes just that subtree. error_code -1 means "path not found"
// (missing field, index out of bounds, or a scalar in the middle of the
// path), which callers surface as null rather than an error.
SJ_EXPORT void sj_at(void* handle, const uint8_t* pointer, uint64_t pointer_length,
           SjResult* result) {
  result->error_code = 0;
  result->error_message = nullptr;
  result->tape = nullptr;
  result->tape_length = 0;

  try {
    auto* document = static_cast<SjDocument*>(handle);
    simdjson::dom::element element;
    const auto error =
        document->root
            .at_pointer(std::string_view(
                reinterpret_cast<const char*>(pointer), pointer_length))
            .get(element);
    if (error) {
      const bool not_found = error == simdjson::NO_SUCH_FIELD ||
                             error == simdjson::INDEX_OUT_OF_BOUNDS ||
                             error == simdjson::INCORRECT_TYPE;
      result->error_code = not_found ? -1 : static_cast<int32_t>(error);
      result->error_message = simdjson::error_message(error);
      return;
    }

    TapeWriter tape;
    const auto write_error = write_element(element, tape);
    if (write_error) {
      result->error_code = static_cast<int32_t>(write_error);
      result->error_message = simdjson::error_message(write_error);
      return;
    }
    size_t tape_length = 0;
    result->tape = tape.release(&tape_length);
    result->tape_length = tape_length;
    if (result->tape == nullptr) {
      fail_alloc(result);
    }
  } catch (...) {
    fail_alloc(result);
  }
}

SJ_EXPORT void sj_close(void* handle) { delete static_cast<SjDocument*>(handle); }

}  // extern "C"
