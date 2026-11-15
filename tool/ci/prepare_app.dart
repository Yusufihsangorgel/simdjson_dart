/// Turns an app made by `flutter create` into the consumer the compat
/// workflow builds by copying the on-device decode test into it.
///
/// Run it as `dart tool/ci/prepare_app.dart <app directory>`.
///
/// The dependency on simdjson_dart is added separately with `flutter pub add`.
library;

import 'dart:io';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart tool/ci/prepare_app.dart <app directory>');
    exit(64);
  }
  final app = Directory(args.single);
  final ci = File.fromUri(Platform.script).parent;

  final to = File('${app.path}/integration_test/decode_test.dart');
  to.parent.createSync(recursive: true);
  File('${ci.path}/integration_test/decode_test.dart').copySync(to.path);
  print('prepared ${app.path}');
}
