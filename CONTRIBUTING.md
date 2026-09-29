# Contributing to simdjson_dart

## Support

One maintainer looks after this package, best effort. There is no promised
response time and no release schedule.

## Bug reports

A good bug report contains:

* The simdjson_dart version your app resolves, from `pubspec.lock`.
* The full output of `dart --version`.
* The operating system it ran on and how the code ran (Dart VM, compiled executable, or a Flutter app).
* A minimal reproduction, the smallest code that shows the problem.

## Setup

Install the Dart SDK. This package needs:

* Dart SDK `^3.10.0`

## Checks

Run these in the repository root. CI runs the same seven commands:

```
dart pub get
dart format --output=none --set-exit-if-changed lib test bench example hook
dart analyze --fatal-infos
dart test
dart run example/simdjson_dart_example.dart
dart run example/ndjson_log_scan.dart
dart run example/ndjson_stream.dart
```

## Pull requests

* One change per pull request.
* Add an entry to `CHANGELOG.md`.
* Link the issue, for example `Fixes #12`.
