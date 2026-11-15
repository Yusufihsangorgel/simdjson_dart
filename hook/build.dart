import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Compiles the simdjson shim (and the vendored simdjson amalgamation)
/// into a dynamic library at build time.
void main(List<String> args) async {
  await build(args, (input, output) async {
    // A build can ask for other asset types only; the code configuration is
    // absent then and reading it throws, so there is nothing to compile.
    if (!input.config.buildCodeAssets) return;

    final targetOS = input.config.code.targetOS;

    final builder = CBuilder.library(
      name: 'simdjson_shim',
      assetName: 'src/bindings.dart',
      sources: [
        'src/simdjson_shim.cpp',
        'src/third_party/simdjson/simdjson.cpp',
      ],
      language: Language.cpp,
      // Translated per compiler (-std= vs /std:); raw flags would be
      // silently ignored by MSVC.
      std: 'c++17',
      // simdjson is C++, and on Android the toolchain links the standard
      // library dynamically by default: the shim comes out with a DT_NEEDED
      // on libc++_shared.so, which an app does not ship unless some other
      // native dependency bundles it. The build stays green and the first
      // call into the shim throws `dlopen failed: library "libc++_shared.so"
      // not found` on the device. Linking it statically makes the shim
      // self-contained. Only Android defaults to the shared form, so the
      // other targets are left alone.
      cppLinkStdLib: targetOS == OS.android ? 'c++_static' : null,
    );
    await builder.run(input: input, output: output);
  });
}
