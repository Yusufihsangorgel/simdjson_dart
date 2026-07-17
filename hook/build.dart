import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Compiles the simdjson shim (and the vendored simdjson amalgamation)
/// into a dynamic library at build time.
void main(List<String> args) async {
  await build(args, (input, output) async {
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
    );
    await builder.run(input: input, output: output);
  });
}
