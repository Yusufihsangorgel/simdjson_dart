/// Checks the simdjson_dart library packed into a release APK.
///
/// Run it as `dart tool/ci/check_apk.dart <app-release.apk>`.
///
/// For each ABI a default `flutter build apk` produces, the library has to be
/// present and every LOAD segment has to be aligned to 16 KB. Devices with
/// 16 KB pages refuse to load anything less. The library may only link
/// against libc, libm and libdl. The shim is C++ and links the C++ standard
/// library statically on Android. The file libc++_shared.so may neither be
/// NEEDED nor be packed into the APK.
///
/// The tool llvm-readelf comes from the Android NDK. It looks at the
/// ANDROID_NDK_HOME variable first, then in the newest NDK under the ndk
/// directory of ANDROID_HOME or ANDROID_SDK_ROOT.
library;

import 'dart:io';

/// The library name that `CBuilder.library` in hook/build.dart builds.
const soName = 'libsimdjson_shim.so';
const abis = ['armeabi-v7a', 'arm64-v8a', 'x86_64'];
const pageSize = 0x4000;
const allowedNeeded = {'libc.so', 'libm.so', 'libdl.so'};

/// Nothing is required. hook/build.dart does not link libm and the compiled
/// sources reference no libm symbol. Add libm.so here if that changes, since
/// Android resolves libm symbols only from a NEEDED entry.
const requiredNeeded = <String>{};

/// The shared C++ runtime. The option `cppLinkStdLib: 'c++_static'` keeps it
/// out.
const sharedCpp = 'libc++_shared.so';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart tool/ci/check_apk.dart <apk>');
    exit(64);
  }
  final apk = File(args.single);
  if (!apk.existsSync()) _fail('no APK at ${apk.path}');

  final readelf = _findReadelf();
  print('llvm-readelf: $readelf');

  final out = Directory.systemTemp.createTempSync('apk_libs');
  try {
    _run('unzip', ['-q', apk.path, 'lib/*', '-d', out.path]);

    final problems = <String>[];
    for (final abi in abis) {
      if (File('${out.path}/lib/$abi/$sharedCpp').existsSync()) {
        problems.add('$abi: $sharedCpp is packed into the APK');
      }
      final so = File('${out.path}/lib/$abi/$soName');
      if (!so.existsSync()) {
        problems.add('$abi: $soName is missing');
        continue;
      }

      final aligns = _loadAlignments(_run(readelf, ['-lW', so.path]));
      final needed = _needed(_run(readelf, ['-d', so.path]));
      print(
        '$abi: ${so.lengthSync()} bytes, LOAD align '
        '${aligns.map((a) => '0x${a.toRadixString(16)}').join(' ')}, '
        'NEEDED ${needed.join(' ')}',
      );

      if (aligns.isEmpty) problems.add('$abi: no LOAD segments');
      for (final align in aligns) {
        if (align < pageSize || align % pageSize != 0) {
          problems.add(
            '$abi: LOAD segment aligned to 0x${align.toRadixString(16)}, '
            'needs 0x${pageSize.toRadixString(16)}',
          );
        }
      }
      for (final name in needed) {
        if (!allowedNeeded.contains(name)) {
          problems.add('$abi: unexpected NEEDED $name');
        }
      }
      for (final name in requiredNeeded) {
        if (!needed.contains(name)) {
          problems.add('$abi: $name is not NEEDED');
        }
      }
    }

    if (problems.isNotEmpty) _fail(problems.join('\n'));
    print('${abis.length} ABIs checked');
  } finally {
    out.deleteSync(recursive: true);
  }
}

/// The Align column of each LOAD line in `llvm-readelf -lW` output.
List<int> _loadAlignments(String programHeaders) => [
  for (final line in programHeaders.split('\n'))
    if (line.trimLeft().startsWith('LOAD '))
      int.parse(line.trim().split(RegExp(r'\s+')).last),
];

/// Library names from the `(NEEDED)` lines of `llvm-readelf -d` output.
List<String> _needed(String dynamicSection) => [
  for (final line in dynamicSection.split('\n'))
    if (line.contains('(NEEDED)'))
      RegExp(r'\[(.+)\]').firstMatch(line)?.group(1) ?? line.trim(),
];

String _findReadelf() {
  final env = Platform.environment;
  final ndks = <String>[?env['ANDROID_NDK_HOME']];
  for (final sdk in [?env['ANDROID_HOME'], ?env['ANDROID_SDK_ROOT']]) {
    final dir = Directory('$sdk/ndk');
    if (!dir.existsSync()) continue;
    final versions = dir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => _compareVersions(b.path, a.path));
    ndks.addAll(versions.map((d) => d.path));
  }
  for (final ndk in ndks) {
    final prebuilt = Directory('$ndk/toolchains/llvm/prebuilt');
    if (!prebuilt.existsSync()) continue;
    for (final host in prebuilt.listSync().whereType<Directory>()) {
      final tool = File('${host.path}/bin/llvm-readelf');
      if (tool.existsSync()) return tool.path;
    }
  }
  _fail(
    'llvm-readelf not found. Looked in ANDROID_NDK_HOME and the ndk '
    'directory of ANDROID_HOME and ANDROID_SDK_ROOT: '
    '${ndks.isEmpty ? 'none of them is set' : ndks.join(', ')}',
  );
}

/// Orders NDK directories such as `.../ndk/27.2.12479018` by version.
int _compareVersions(String a, String b) {
  List<int> parse(String path) => [
    for (final part in path.split('/').last.split('.')) int.tryParse(part) ?? 0,
  ];
  final x = parse(a);
  final y = parse(b);
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return x.length.compareTo(y.length);
}

String _run(String executable, List<String> args) {
  final result = Process.runSync(executable, args);
  if (result.exitCode != 0) {
    _fail(
      '$executable ${args.join(' ')} exited with ${result.exitCode}\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return result.stdout as String;
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
