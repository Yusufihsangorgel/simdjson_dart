/// Checks that an app depending on simdjson_dart resolved the native-assets
/// packages to the versions expected for its Flutter release line.
///
/// Run it on the output of `pub deps`.
///
/// ```
/// flutter pub deps --json > deps.json
/// dart tool/ci/check_resolution.dart deps.json hooks=2.0.2 'code_assets>=1.2'
/// ```
///
/// An argument `name=version` wants exactly that version and `name>=version`
/// wants that version or a newer one. A shell needs the second form quoted.
/// It prints the resolved version of every named package and exits with 1 if
/// one is missing or does not match.
library;

import 'dart:convert';
import 'dart:io';

/// The package under test. It has to resolve from the checkout.
const package = 'simdjson_dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart tool/ci/check_resolution.dart <deps.json> '
      '(name=version | name>=version)...',
    );
    exit(64);
  }

  final expected = <String, _Expectation>{};
  for (final arg in args.skip(1)) {
    final match = RegExp(
      r'^([^=<>\s]+)(>=|=)(\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.+-]+)?)$',
    ).firstMatch(arg);
    if (match == null) {
      stderr.writeln('expected name=version or name>=version, got "$arg"');
      exit(64);
    }
    expected[match[1]!] = _Expectation(
      atLeast: match[2] == '>=',
      version: match[3]!,
    );
  }

  final resolved = _readVersions(File(args.first));

  // The package has to come from the checkout, or the check proves nothing.
  // meta is printed because the Flutter SDK pins it, and that pin decides
  // which releases of the packages below pub can pick.
  final self = resolved[package];
  print('${package.padRight(20)}${self?.describe() ?? 'missing'}');
  print('${'meta'.padRight(20)}${resolved['meta']?.describe() ?? 'missing'}');

  var failed = self == null || self.source != 'path';
  for (final MapEntry(key: name, value: want) in expected.entries) {
    final got = resolved[name]?.version;
    final ok = got != null && want.accepts(got);
    if (!ok) failed = true;
    print(
      '${name.padRight(20)}${(got ?? 'missing').padRight(10)}'
      'expected ${want.describe()}${ok ? '' : '  MISMATCH'}',
    );
  }
  if (failed) exit(1);
}

/// Reads the package list from `pub deps --json` output.
///
/// The Flutter tool can print a notice before the JSON on a fresh machine.
/// Parsing starts at the first line that opens an object.
Map<String, _Package> _readVersions(File file) {
  final lines = file.readAsLinesSync();
  final start = lines.indexWhere((line) => line.startsWith('{'));
  if (start < 0) {
    stderr.writeln('no JSON object in ${file.path}');
    exit(1);
  }
  final json = jsonDecode(lines.skip(start).join('\n')) as Map<String, Object?>;
  return {
    for (final package in json['packages'] as List<Object?>)
      if (package case {
        'name': final String name,
        'version': final String version,
        'source': final String source,
      })
        name: _Package(version, source),
  };
}

final class _Package {
  _Package(this.version, this.source);

  final String version;
  final String source;

  String describe() => '$version ($source)';
}

/// One `name=version` or `name>=version` argument.
final class _Expectation {
  _Expectation({required this.atLeast, required this.version});

  /// Whether a newer version is acceptable as well.
  final bool atLeast;
  final String version;

  bool accepts(String resolved) =>
      atLeast ? _compareVersions(resolved, version) >= 0 : resolved == version;

  String describe() => '${atLeast ? '>=' : ''}$version';
}

/// Orders two semantic versions. Build metadata is ignored and a pre-release
/// sorts before its release.
int _compareVersions(String a, String b) {
  (List<int>, List<String>) split(String version) {
    final withoutBuild = version.split('+').first;
    final dash = withoutBuild.indexOf('-');
    final core = dash < 0 ? withoutBuild : withoutBuild.substring(0, dash);
    final pre = dash < 0
        ? <String>[]
        : withoutBuild.substring(dash + 1).split('.');
    return ([for (final part in core.split('.')) int.tryParse(part) ?? 0], pre);
  }

  final (coreA, preA) = split(a);
  final (coreB, preB) = split(b);
  for (var i = 0; i < coreA.length || i < coreB.length; i++) {
    final x = i < coreA.length ? coreA[i] : 0;
    final y = i < coreB.length ? coreB[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  if (preA.isEmpty != preB.isEmpty) return preA.isEmpty ? 1 : -1;
  for (var i = 0; i < preA.length && i < preB.length; i++) {
    final x = int.tryParse(preA[i]);
    final y = int.tryParse(preB[i]);
    final order = switch ((x, y)) {
      (final int p, final int q) => p.compareTo(q),
      (int(), null) => -1,
      (null, int()) => 1,
      _ => preA[i].compareTo(preB[i]),
    };
    if (order != 0) return order;
  }
  return preA.length.compareTo(preB.length);
}
