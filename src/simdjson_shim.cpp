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
#include <string>
#include <vector>

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
      tape.u32(static_cast<uint32_t>(array.size()));
      for (auto child : array) {
        auto child_error = write_element(child, tape);
        if (child_error) return child_error;
      }
      return simdjson::SUCCESS;
    }
    case simdjson::dom::element_type::OBJECT: {
      simdjson::dom::object object;
      auto error = element.get(object);
      if (error) return error;
      tape.u8(0x07);
      tape.u32(static_cast<uint32_t>(object.size()));
      for (auto field : object) {
        const std::string_view key = field.key;
        tape.u32(static_cast<uint32_t>(key.size()));
        tape.raw(key.data(), key.size());
        auto child_error = write_element(field.value, tape);
        if (child_error) return child_error;
      }
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

void sj_parse(const uint8_t* json, uint64_t length, SjResult* result) {
  result->error_code = 0;
  result->error_message = nullptr;
  result->tape = nullptr;
  result->tape_length = 0;

  static thread_local simdjson::dom::parser parser;
  simdjson::dom::element root;
  const auto error = parser
                         .parse(reinterpret_cast<const char*>(json), length)
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
    result->error_code = static_cast<int32_t>(simdjson::MEMALLOC);
    result->error_message = simdjson::error_message(simdjson::MEMALLOC);
  }
}

void sj_free(uint8_t* tape) { std::free(tape); }

// A parsed document held open for lazy, repeated access. The parser owns
// the underlying tape, so it lives alongside the root element.
struct SjDocument {
  simdjson::dom::parser parser;
  simdjson::dom::element root;
};

// Parses and keeps the document open. Returns null on error, with the
// details in `result`.
void* sj_open(const uint8_t* json, uint64_t length, SjResult* result) {
  result->error_code = 0;
  result->error_message = nullptr;
  result->tape = nullptr;
  result->tape_length = 0;

  auto* document = new SjDocument();
  const auto error =
      document->parser.parse(reinterpret_cast<const char*>(json), length)
          .get(document->root);
  if (error) {
    result->error_code = static_cast<int32_t>(error);
    result->error_message = simdjson::error_message(error);
    delete document;
    return nullptr;
  }
  return document;
}

// Resolves a JSON Pointer (RFC 6901) inside an open document and
// serializes just that subtree. error_code -1 means "path not found"
// (missing field, index out of bounds, or a scalar in the middle of the
// path), which callers surface as null rather than an error.
void sj_at(void* handle, const uint8_t* pointer, uint64_t pointer_length,
           SjResult* result) {
  result->error_code = 0;
  result->error_message = nullptr;
  result->tape = nullptr;
  result->tape_length = 0;

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
    result->error_code = static_cast<int32_t>(simdjson::MEMALLOC);
    result->error_message = simdjson::error_message(simdjson::MEMALLOC);
  }
}

void sj_close(void* handle) { delete static_cast<SjDocument*>(handle); }

}  // extern "C"
