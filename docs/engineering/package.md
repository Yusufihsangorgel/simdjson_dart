# Package engineering rules: simdjson_dart

Rules-Version: simdjson_dart/852e0ca8da9d02675e65a481c8d69c62ece28c63263f34de0083af05ddd38941
Core-Version: 1
Core-Digest: 1825fa7ff346dca23e65b1b3bf9b2e3e06959f1414bae9952d596d2f62f09b8f
Survey-Digest: f90f45c8a172068c3ed3b9488ba5a7cb4e58efa93c380d2d9a70b399349ec35e
Evidence-Revision: 2bc4de6
Verified-Revision: unverified

Read CONTRIBUTING.md and docs/engineering/debt.json before editing.

## Current architecture
HEAD 2bc4de6 (1.6.1). There is a 642-line C++17 shim around the simdjson C++ amalgamation. The shim returns results in a binary 'tape' format. The Dart side converts it to objects with `_TapeReader` and interns keys by FNV-1a hash. There are three functional files. `decoder.dart` holds full-buffer decode, NDJSON bytes, the tape reader, and native allocation helpers. `document.dart` is `SimdJsonDocument`: lazy RFC 6901 access (at/atMany/exists) and openFile. `ndjson_stream.dart` does streaming NDJSON decode/select. Its byte carry buffer is `_NdjsonCarry`. The error contract is pinned by test/error_contract_test.dart. Three points deviate from the siblings: the C runtime malloc/free is bound directly with `@Native`; there is no package:ffi or code_assets dependency; the hook has no `buildCodeAssets` guard and there is no hook test.

## Layers and responsibilities
- lib/simdjson_dart.dart: Only `export ... show` (lines 12-24).
- lib/src/ndjson_stream.dart: NDJSON decode/select stream and file; `_NdjsonCarry`; turning an IO error into FormatException('IO_ERROR').
- lib/src/document.dart: SimdJsonDocument: parse/parseBytes/openFile, at, atMany (batched pointer encoding), exists, close.
- lib/src/decoder.dart: simdJsonDecode*, decodeTape/decodeTapeMany, errorMessageOf, allocateBytes/freeBytes/allocateResult/freeResult, C runtime malloc/free bindings.
- lib/src/bindings.dart: SjResult struct, 8 `@Native` (sj_parse, sj_parse_ndjson, sj_free, sj_open, sj_open_file, sj_at, sj_at_many, sj_close).
- src/simdjson_shim.cpp, src/third_party/simdjson/: `SJ_EXPORT`, extern C, try/catch(...), tape serialization.
- hook/build.dart: CBuilder C++17; no guard.
- test/, example/, bench/, docs/ (not published): 10 test files plus 2 separate-process probes; 3 examples that run in CI; a GH Archive report and a friction log.

## Public API and dependency direction
Functions: simdJsonDecode(String), simdJsonDecodeBytes(Uint8List), simdJsonDecodeNdjson, simdJsonDecodeNdjsonBytes, simdJsonDecodeNdjsonStream(Stream<List<int>>), simdJsonDecodeNdjsonFile(path, {chunkSize = 64 KiB}), simdJsonSelectNdjsonStream(source, jsonPointers, {existencePointers}), simdJsonSelectNdjsonFile. Type: SimdJsonDocument (parse, parseBytes, openFile; at, atMany, exists, close, isClosed). Return shapes match jsonDecode. The boundary is lib/simdjson_dart.dart:12-24.

simdjson_dart.dart -> {decoder, document, ndjson_stream}. ndjson_stream -> decoder, document, dart:io. document -> bindings, decoder. decoder -> bindings (+ C runtime malloc/free @Native). bindings -> dart:ffi. No cycle. The tape format is a binary contract shared between decoder.dart and src/simdjson_shim.cpp.

## Error, state and platform contracts
- Padded input: JSON bytes plus 64 zero bytes (SIMDJSON_PADDING) (decoder.dart:19-27).
- SjResult out-param struct (errorCode, errorMessage, tape, tapeLength). Nested try/finally: tape `sjFree`, result `freeResult`, input `freeBytes` (decoder.dart:21-47).
- Tape: tag byte 0x00-0x07, u32 numbers, little-endian; key interning (decoder.dart:171-274).
- Errors: FormatException (simdjson diagnostics; 'IO_ERROR: ...' for files), StateError (closed document, allocation, malformed tape), ArgumentError (chunkSize). On full-buffer paths a number range error falls through to jsonDecode (decoder.dart:120-131; ndjson_stream.dart:247-249).
- Lifecycle names are close/isClosed; the finalizer uses `Native.addressOf(sjClose)` (document.dart:113-123, 319-326).
- Streaming: `async*` plus the `_NdjsonCarry` compaction invariant. Memory holds only a chunk and a partial line (ndjson_stream.dart:49-67, 252-309).
- Dartdoc cites the API rationale: 'API justification: friction log sections ...' (document.dart:193-194; ndjson_stream.dart:97-98, 183).
- Leak measurement runs in a separate process (test/leak_probe.dart:1-11) and is skipped on Windows (native_safety_test.dart:89, 139, 194).
- CI runs the examples the README quotes (ci.yaml:28-33).
- `.pubignore` is kept a superset of `.gitignore` (.pubignore comments).
- Global state is only `const` (_newline, _defaultChunkSize) and a `static final NativeFinalizer`.
- Documentation layout: AGENTS.md targets users.

## Package rules
### simdjson_dart/SJ-01 [MUST]
The public API is exposed only through the `lib/simdjson_dart.dart` show lists; decodeTape, allocate* and bindings are not exported.
Reason: The tape and memory helpers are an internal contract.
Evidence: lib/simdjson_dart.dart:12-24
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-02 [MUST]
The error contract is pinned by test/error_contract_test.dart: invalid JSON or pointer -> FormatException (simdjson diagnosis); unreadable file -> FormatException('IO_ERROR: ...'); closed document -> StateError; chunkSize < 1 -> a synchronous ArgumentError. A diff that changes the contract updates the test in the same commit.
Reason: 1.6.1 'Pin the public error contract' fixed this contract in a test together with the exception type and message.
Evidence: lib/src/decoder.dart:35, 95; lib/src/document.dart:47-49, 90-92, 149-151; lib/src/ndjson_stream.dart:190-192, 247-249; CHANGELOG.md:1-6
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-03 [MUST]
Every JSON byte input given to simdjson is a copy padded with 64 zero bytes.
Reason: simdjson reads up to 64 bytes past the end of the input (SIMDJSON_PADDING); unpadded input reads out of bounds.
Evidence: lib/src/decoder.dart:19-27, 74-82; lib/src/document.dart:39-45
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-04 [MUST]
The native result returns through an `SjResult` out-param struct. The tape is freed with `sjFree`, the result with `freeResult`, and the input with `freeBytes`, on every path including error paths, inside nested try/finally.
Reason: 1.6.1 'free native inputs on every path'; the leak is measured with probes.
Evidence: lib/src/decoder.dart:21-47; lib/src/document.dart:153-174, 256-277; CHANGELOG.md:1-6
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-05 [MUST]
The tape format (tags 0x00-0x07, u32 numbers, little-endian) is a shared contract with the shim; if one changes, both change in the same diff.
Reason: If one side changes alone, `_TapeReader` throws 'corrupt tape' or produces a wrong value.
Evidence: lib/src/decoder.dart:171-217; lib/src/bindings.dart:28-29; src/simdjson_shim.cpp
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-06 [MUST]
Only the full-document decode paths fall back to jsonDecode on number range errors (NUMBER_ERROR, BIGINT_ERROR). The selective paths (SimdJsonDocument, select stream) do not fall back; they throw FormatException. The fallback set is not widened.
Reason: The jsonDecode shape-parity promise; widening the set masks input that is genuinely broken.
Evidence: lib/src/decoder.dart:120-131; lib/src/ndjson_stream.dart:93-95
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-07 [MUST]
The SimdJsonDocument lifecycle uses the names `close()`/`isClosed` (not dispose). The NativeFinalizer is attached with `Native.addressOf(sjClose)`, and close is idempotent.
Reason: Naming consistency inside the package and a documented contract.
Evidence: lib/src/document.dart:113-123, 319-326
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-08 [MUST]
The NDJSON stream keeps only the current chunk and the unfinished line in memory (`_NdjsonCarry`: no 0x0A in the buffer after compact); a path that collects the whole file is not added.
Reason: The reason the streaming API exists is NDJSON that does not fit in memory.
Evidence: lib/src/ndjson_stream.dart:18-41, 252-309
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-09 [MUST]
On the selective NDJSON path, the native document of every line is closed before the map is emitted; the caller gets no native handle.
Reason: Published values must remain valid as the stream advances.
Evidence: lib/src/ndjson_stream.dart:88-91, 143-158
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-10 [MUST]
The extern C entries in the C++ shim stay wrapped in `try/catch(...)`; a C++ exception does not cross the C ABI.
Reason: simdjson and std exceptions are undefined behavior at the FFI boundary.
Evidence: src/simdjson_shim.cpp:26-28, 227, 257-285, 301-370
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-11 [MUST]
The sample outputs quoted in the README come from examples that CI runs; a new example quoted into the README is added to a CI step.
Reason: Analysis only shows that it compiles; it does not show that the output matches the document.
Evidence: .github/workflows/ci.yaml:28-33
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-12 [MUST]
RSS and leak measurement runs in a separate process (test/leak_probe.dart, test/ndjson_stream_probe.dart), not inside the `dart test` process. These tests are skipped on Windows with `testOn: '!windows'`.
Reason: Concurrent suites in the same process produce unrelated growth above 500 MB (measured).
Evidence: test/leak_probe.dart:1-11; test/native_safety_test.dart:89, 139, 194
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-13 [SHOULD]
The dartdoc of a new public API carries a rationale sentence that cites a source showing the need (a friction log section or a measurement).
Reason: Repository pattern; API expansion is tied to measured friction.
Evidence: lib/src/document.dart:193-194; lib/src/ndjson_stream.dart:97-98, 183
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-14 [MUST]
`.pubignore` stays a superset of `.gitignore`; docs/ is not published.
Reason: .pubignore replaces .gitignore rather than extending it; build/ leaked into the archive once (measured).
Evidence: .pubignore (comment lines and the list)
Evidence role: current-pattern
Existing violation: none

### simdjson_dart/SJ-15 [MUST]
Native memory is taken only through allocateBytes/freeBytes/allocateResult/freeResult in decoder.dart; a second allocation path is not opened.
Reason: Allocation and deallocation must stay in the same CRT; the current deviation is in the debt register.
Evidence: lib/src/decoder.dart:144-169
Evidence role: counterexample
Existing violation: simdjson_dart-D002

### simdjson_dart/SJ-16 [MUST]
A new reading path follows this skeleton: `SjResult` + allocateResult/freeResult + (for JSON) a 64-byte padded input + decodeTape + sjFree. If the tape needs a new tag, the shim and `_TapeReader` change in the same diff.
Reason: The current extension point.
Evidence: lib/src/decoder.dart:18-48, 171-217; lib/src/document.dart:148-175
Evidence role: current-pattern
Existing violation: none

## Required verification
- Working directory: repository root; command: dart pub get; conditions: ci.yaml job test; evidence: .github/workflows/ci.yaml:23.
- Working directory: repository root; command: dart format --output=none --set-exit-if-changed lib test bench example hook; conditions: ci.yaml job test; evidence: .github/workflows/ci.yaml:24.
- Working directory: repository root; command: dart analyze --fatal-infos; conditions: ci.yaml job test; evidence: .github/workflows/ci.yaml:25.
- Working directory: repository root; command: dart test; conditions: ci.yaml job test; evidence: .github/workflows/ci.yaml:26.
- Working directory: repository root; command: dart run example/simdjson_dart_example.dart; conditions: ci.yaml job test; evidence: .github/workflows/ci.yaml:31.
- Working directory: repository root; command: dart run example/ndjson_log_scan.dart; conditions: ci.yaml job test; evidence: .github/workflows/ci.yaml:32.
- Working directory: repository root; command: dart run example/ndjson_stream.dart; conditions: ci.yaml job test; evidence: .github/workflows/ci.yaml:33.
Not verified by the survey:
- `dart analyze`/`dart test` were not run (read-only scope).
- Which module resolves `@Native(symbol: 'malloc')` on Windows, and whether CI is green on Windows (no network).
- The native cost difference between exists and the atMany existence mode was not measured. The shim's 642 lines were scanned only through export and try/catch markers.
- Whether the unguarded hook actually skips a build that does not request code assets (CBuilder.run behavior) was not measured.
- The vendored simdjson version and its currency were not verified. A shim comment references 4.6.4 (simdjson_shim.cpp:93).

## Existing debt
The complete register is docs/engineering/debt.json.
- simdjson_dart-D001 | small | hook/build.dart:6-21; pubspec.yaml:42-44; test/hook_test.dart (missing) | deviation from siblings / missing test
  Fix: Add `code_assets: ^2.0.0`, add the guard line, add the test/hook_test.dart from the siblings, and record it in CHANGELOG.
  Closure: hook/build.dart returns early when input.config.buildCodeAssets is false, pubspec.yaml declares code_assets and test/hook_test.dart covers the code-asset-free path. CHANGELOG.md records the change.
- simdjson_dart-D002 | small | lib/src/decoder.dart:144-169 | inconsistency (FFI memory)
  Fix: Export `sj_alloc`/`sj_dealloc` from the shim (allocation and deallocation in the same CRT) or document the resolution path in a comment + a Windows test.
  Closure: Either the shim exports sj_alloc and sj_dealloc and decoder.dart uses only those, or a comment documents the Windows resolution path and a Windows test covers it.
- simdjson_dart-D003 | small | lib/src/decoder.dart:18-48, 73-108; lib/src/document.dart:39-45 | duplicated logic + magic number
  Fix: `const _simdjsonPadding = 64` + a `copyPadded(Uint8List)` helper; both decode paths call the shared private function.
  Closure: A single copyPadded helper with const _simdPadding = 64 serves every padded-copy site and both byte decode paths call it.
- simdjson_dart-D004 | small | lib/src/document.dart:149-151, 199-201, 208-210, 217-219, 293-295; 152-174 <-> 296-316 | duplicated logic
  Fix: `_checkOpen()` and a shared private `_lookup` helper.
  Closure: The five inline _closed checks call a shared _checkOpen and the at and exists lookups share one private helper.
- simdjson_dart-D005 | medium | lib/src/document.dart:292-316 (<-> 228-230) | performance
  Fix: Route exists to the existence mode or a separate `sj_exists` shim entry; keep exists_test and add a cost measurement.
  Closure: exists routes through the atMany existence mode or a dedicated sj_exists shim entry. exists_test stays green and a recorded cost measurement shows the value tape is no longer built.
- simdjson_dart-D006 | small | lib/src/decoder.dart:131 | magic number / no source link
  Fix: Return a named flag from the shim or record the vendored version and the enum names in a comment.
  Closure: The shim returns a named fallback flag or a comment records the vendored simd version and the enum names behind codes 9 and 10. The decoder_test.dart group at line 86 stays green.
- simdjson_dart-D007 | small | analysis_options.yaml:1-30 | analysis strictness + template noise
  Fix: Clean up the template and turn on the image_ffi settings.
  Closure: analysis_options.yaml carries no template comments and enables the image_ffi strict settings with no new diagnostics from dart analyze.
