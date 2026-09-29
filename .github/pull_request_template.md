Issue: #<number>

Checklist, matching CI. Run in the repository root:

- [ ] `dart pub get`
- [ ] `dart format --output=none --set-exit-if-changed lib test bench example hook`
- [ ] `dart analyze --fatal-infos`
- [ ] `dart test`
- [ ] `dart run example/simdjson_dart_example.dart`
- [ ] `dart run example/ndjson_log_scan.dart`
- [ ] `dart run example/ndjson_stream.dart`
- [ ] `CHANGELOG.md` entry added
