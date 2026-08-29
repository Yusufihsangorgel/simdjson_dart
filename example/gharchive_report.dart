// Stream one GH Archive hour and answer a few questions about it.
//
// GH Archive publishes GitHub's public event stream as one gzipped NDJSON
// file per hour (https://data.gharchive.org/). Each line is one event:
// a PushEvent, a PullRequestEvent, a WatchEvent, and so on. The records
// are deeply nested and they are not the same shape — PushEvent has no
// `payload.action`, most events have no `org`, and
// `payload.pull_request.base.repo.language` is often JSON null rather
// than absent. That is the kind of file this package's NDJSON APIs exist
// to read.
//
// The report is something a person would actually want from the hour:
// which event types ran, which repos were busiest, how many events were
// unattributed to an org, and — for pull-request-bearing records — the
// merged flag and the repo language, including the null/absent split.
//
// It is also a contact test. The extraction wants four nested fields per
// record and wants to keep going when they are missing. What the public
// API made easy, and what it did not, is written down in
// example/gharchive_friction.md. This file does not invent helpers on
// the package to paper over that.
//
// The dataset is not in git. Fetch it first:
//
//   mkdir -p data
//   curl -L -o data/2024-07-07-6.json.gz \
//     https://data.gharchive.org/2024-07-07-6.json.gz
//
// Then:
//
//   dart run example/gharchive_report.dart
//   dart run example/gharchive_report.dart --decoder=convert
//   dart run example/gharchive_report.dart --decoder=pointers
//
// Default path is data/2024-07-07-6.json.gz. Pass another hour, gzipped
// or already decompressed, as a positional argument.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:simdjson_dart/simdjson_dart.dart';

const _defaultPath = 'data/2024-07-07-6.json.gz';
const _sampleEvery = 20000;
const _topN = 15;

void main(List<String> args) async {
  var decoder = 'simdjson';
  String? path;
  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      _usage();
      return;
    }
    if (arg.startsWith('--decoder=')) {
      decoder = arg.substring('--decoder='.length);
      continue;
    }
    if (arg.startsWith('-')) {
      stderr.writeln('unknown flag: $arg');
      _usage();
      exitCode = 64;
      return;
    }
    path = arg;
  }
  if (decoder != 'simdjson' && decoder != 'convert' && decoder != 'pointers') {
    stderr.writeln(
      '--decoder must be simdjson, convert, or pointers, not $decoder',
    );
    exitCode = 64;
    return;
  }

  final file = File(path ?? _defaultPath);
  if (!file.existsSync()) {
    stderr.writeln('no such file: ${file.path}');
    stderr.writeln('fetch a GH Archive hour first, for example:');
    stderr.writeln(
      '  mkdir -p data && curl -L -o $_defaultPath '
      'https://data.gharchive.org/2024-07-07-6.json.gz',
    );
    exitCode = 66;
    return;
  }

  final report = _Report();
  final wall = Stopwatch()..start();
  report.sampleRss();
  try {
    if (decoder == 'pointers') {
      // The call the extraction actually wanted: JSON pointers on each
      // record, without building the rest of the event. The package has
      // no NDJSON entry that does this, so this branch splits lines
      // itself, constructs a SimdJsonDocument per record, and closes it.
      await _addFromPointers(file, report);
    } else {
      await for (final row in _records(file, decoder)) {
        report.add(row);
      }
    }
  } on FormatException catch (e) {
    wall.stop();
    stderr.writeln(
      'parse failed after ${report.records} records: ${e.message}',
    );
    exitCode = 1;
    return;
  }
  wall.stop();
  report.sampleRss();
  report.printTo(stdout, file: file, decoder: decoder, wall: wall.elapsed);
}

/// One decoded event at a time, from gzip or raw NDJSON.
///
/// `simdJsonDecodeNdjsonFile` is the path-shaped entry the package
/// documents for a log that should not sit in a `Uint8List`. It reads
/// raw bytes. GH Archive ships `.json.gz`, so the gzipped default path
/// cannot use it: the file is not NDJSON until it has been inflated.
/// The Stream entry wraps `gzip.decoder`. `dart:convert` takes the same
/// inflated byte stream and runs `jsonDecode` per line.
Stream<Object?> _records(File file, String decoder) {
  final gzipped = file.path.endsWith('.gz');
  if (decoder == 'simdjson') {
    if (gzipped) {
      return simdJsonDecodeNdjsonStream(
        file.openRead().transform(gzip.decoder),
      );
    }
    return simdJsonDecodeNdjsonFile(file.path);
  }
  Stream<List<int>> bytes = file.openRead();
  if (gzipped) {
    bytes = bytes.transform(gzip.decoder);
  }
  return bytes
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((line) => line.isNotEmpty)
      .map<Object?>(jsonDecode);
}

/// Per-record [SimdJsonDocument]: the selective-access API applied to
/// NDJSON the only way the public surface allows.
Future<void> _addFromPointers(File file, _Report report) async {
  Stream<List<int>> bytes = file.openRead();
  if (file.path.endsWith('.gz')) {
    bytes = bytes.transform(gzip.decoder);
  }
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    // `parse` takes a String. The line was just UTF-8-decoded, and
    // parse will encode it again. `parseBytes` would skip that if the
    // splitter had left us bytes; LineSplitter does not.
    final doc = SimdJsonDocument.parse(line);
    try {
      report.addDocument(doc);
    } finally {
      doc.close();
    }
  }
}

void _usage() {
  stdout.writeln('''
Usage: dart run example/gharchive_report.dart [options] [file]

Stream a GH Archive hourly NDJSON file (gzipped or raw), pull a few
nested fields from each event, and print a report.

Options:
  --decoder=simdjson   package NDJSON stream (default)
  --decoder=convert    dart:convert jsonDecode per line
  --decoder=pointers   SimdJsonDocument.at per record (DIY line split)
  -h, --help           this message

Default file: $_defaultPath
''');
}

/// Walks a nested map the way [SimdJsonDocument.at] would, except the
/// NDJSON APIs do not return a document — they return the materialized
/// `jsonDecode` shape — so this lives in the tool.
Object? _at(Object? root, List<String> path) {
  Object? current = root;
  for (final key in path) {
    if (current is! Map) return null;
    current = current[key];
  }
  return current;
}

/// Walks a nested map the way [SimdJsonDocument.exists] would, for the
/// same reason [_at] exists: `exists` is not on the decoded value.
bool _has(Object? root, List<String> path) {
  Object? current = root;
  for (final key in path) {
    if (current is! Map) return false;
    if (!current.containsKey(key)) return false;
    current = current[key];
  }
  return true;
}

String? _string(Object? value) => value is String ? value : null;

class _Report {
  int records = 0;
  int nonObjects = 0;
  int missingType = 0;
  int missingRepo = 0;
  int missingActor = 0;
  int missingOrg = 0;
  int missingAction = 0;
  int pullRequests = 0;
  int mergedTrue = 0;
  int mergedFalse = 0;
  int mergedNull = 0;
  int mergedMissing = 0;
  int languageNull = 0;
  int languageMissing = 0;

  final Map<String, int> types = {};
  final Map<String, int> repos = {};
  final Map<String, int> languages = {};
  final Set<String> actors = {};

  final List<({int records, int rss})> rssSamples = [];
  int peakRss = 0;

  void add(Object? row) {
    records++;
    if (records % _sampleEvery == 0) sampleRss();

    // A typed `as Map<String, Object?>` is what the README shows for
    // NDJSON rows, and a typed `as Map<String, dynamic>` is what
    // jsonDecode produces. The two are not subtypes of each other, so
    // a shared extraction that both decoders have to survive uses `Map`.
    if (row is! Map) {
      nonObjects++;
      return;
    }

    final type = _string(_at(row, ['type']));
    if (type == null) {
      missingType++;
    } else {
      types[type] = (types[type] ?? 0) + 1;
    }

    final repo = _string(_at(row, ['repo', 'name']));
    if (repo == null) {
      missingRepo++;
    } else {
      repos[repo] = (repos[repo] ?? 0) + 1;
    }

    final actor = _string(_at(row, ['actor', 'login']));
    if (actor == null) {
      missingActor++;
    } else {
      actors.add(actor);
    }

    // `org` is omitted on events from a user repo. JSON null is not
    // the usual encoding; absence is.
    if (!_has(row, ['org'])) missingOrg++;

    // PushEvent and CreateEvent have no `payload.action`. Issues and
    // pull requests do (`opened`, `closed`, `started`, …).
    if (!_has(row, ['payload', 'action'])) missingAction++;

    if (!_has(row, ['payload', 'pull_request'])) return;
    pullRequests++;

    if (!_has(row, ['payload', 'pull_request', 'merged'])) {
      mergedMissing++;
    } else {
      switch (_at(row, ['payload', 'pull_request', 'merged'])) {
        case true:
          mergedTrue++;
        case false:
          mergedFalse++;
        case null:
          mergedNull++;
      }
    }

    // Language is a string, JSON null (known repo, unknown language),
    // or a missing key. `at` alone cannot tell the last two apart.
    if (!_has(row, ['payload', 'pull_request', 'base', 'repo', 'language'])) {
      languageMissing++;
    } else {
      final language = _at(row, [
        'payload',
        'pull_request',
        'base',
        'repo',
        'language',
      ]);
      if (language == null) {
        languageNull++;
      } else if (language is String) {
        languages[language] = (languages[language] ?? 0) + 1;
      }
    }
  }

  /// Same extraction as [add], through [SimdJsonDocument.at] / [exists].
  void addDocument(SimdJsonDocument doc) {
    records++;
    if (records % _sampleEvery == 0) sampleRss();

    final type = _string(doc.at('/type'));
    if (type == null) {
      missingType++;
    } else {
      types[type] = (types[type] ?? 0) + 1;
    }

    final repo = _string(doc.at('/repo/name'));
    if (repo == null) {
      missingRepo++;
    } else {
      repos[repo] = (repos[repo] ?? 0) + 1;
    }

    final actor = _string(doc.at('/actor/login'));
    if (actor == null) {
      missingActor++;
    } else {
      actors.add(actor);
    }

    if (!doc.exists('/org')) missingOrg++;
    if (!doc.exists('/payload/action')) missingAction++;
    if (!doc.exists('/payload/pull_request')) return;
    pullRequests++;

    if (!doc.exists('/payload/pull_request/merged')) {
      mergedMissing++;
    } else {
      switch (doc.at('/payload/pull_request/merged')) {
        case true:
          mergedTrue++;
        case false:
          mergedFalse++;
        case null:
          mergedNull++;
      }
    }

    if (!doc.exists('/payload/pull_request/base/repo/language')) {
      languageMissing++;
    } else {
      final language = doc.at('/payload/pull_request/base/repo/language');
      if (language == null) {
        languageNull++;
      } else if (language is String) {
        languages[language] = (languages[language] ?? 0) + 1;
      }
    }
  }

  void sampleRss() {
    final rss = ProcessInfo.currentRss;
    rssSamples.add((records: records, rss: rss));
    peakRss = max(peakRss, rss);
    peakRss = max(peakRss, ProcessInfo.maxRss);
  }

  void printTo(
    StringSink out, {
    required File file,
    required String decoder,
    required Duration wall,
  }) {
    final size = file.lengthSync();
    out.writeln('file     ${file.path}');
    out.writeln('size     ${_bytes(size)}');
    out.writeln('decoder  $decoder');
    out.writeln('records  $records');
    if (nonObjects != 0) out.writeln('non-objects $nonObjects');
    out.writeln('wall     ${_ms(wall)}');
    out.writeln(
      'rss      peak ${_bytes(max(peakRss, ProcessInfo.maxRss))}'
      '  start ${_bytes(rssSamples.first.rss)}'
      '  end ${_bytes(rssSamples.last.rss)}',
    );
    out.writeln('rss samples (records → resident):');
    for (final sample in rssSamples) {
      out.writeln(
        '  ${sample.records.toString().padLeft(8)}  ${_bytes(sample.rss)}',
      );
    }
    out.writeln('memory   ${_memoryTrend()}');
    out.writeln('');

    out.writeln('event types');
    for (final entry in _top(types, types.length)) {
      out.writeln('  ${_pad(entry.value)}  ${entry.key}');
    }
    out.writeln('');

    out.writeln('top $_topN repos');
    for (final entry in _top(repos, _topN)) {
      out.writeln('  ${_pad(entry.value)}  ${entry.key}');
    }
    out.writeln(
      '  (${repos.length} unique repos, ${actors.length} unique actors)',
    );
    out.writeln('');

    out.writeln('missing fields (null-safe extraction, no crash)');
    out.writeln('  ${_pad(missingType)}  type absent or not a string');
    out.writeln('  ${_pad(missingRepo)}  repo.name absent or not a string');
    out.writeln('  ${_pad(missingActor)}  actor.login absent or not a string');
    out.writeln('  ${_pad(missingOrg)}  org key absent');
    out.writeln('  ${_pad(missingAction)}  payload.action absent');
    out.writeln('');

    out.writeln('pull_request objects ($pullRequests records)');
    out.writeln('  ${_pad(mergedTrue)}  merged true');
    out.writeln('  ${_pad(mergedFalse)}  merged false');
    out.writeln('  ${_pad(mergedNull)}  merged JSON null');
    out.writeln('  ${_pad(mergedMissing)}  merged key absent');
    out.writeln('  ${_pad(languageNull)}  base.repo.language JSON null');
    out.writeln('  ${_pad(languageMissing)}  base.repo.language key absent');
    out.writeln('  languages:');
    for (final entry in _top(languages, 10)) {
      out.writeln('    ${_pad(entry.value)}  ${entry.key}');
    }
  }

  /// Peak resident size of a streaming fold should not track the file.
  /// Unique-repo / unique-actor maps grow with cardinality, which on
  /// this hour is tens of thousands of short strings, not hundreds of
  /// megabytes. A decoder leak would still show up as RSS climbing in
  /// step with records after those maps have been seen.
  String _memoryTrend() {
    if (rssSamples.length < 3) return 'not enough samples';
    final afterStart = rssSamples.skip(1).toList();
    final lo = afterStart.map((s) => s.rss).reduce(min);
    final hi = afterStart.map((s) => s.rss).reduce(max);
    final last = afterStart.last.rss;
    // Unique-repo / unique-actor maps grow with cardinality. A decoder
    // that retained each event would climb by hundreds of MB on this
    // file, not by the width of this band.
    return 'did not track file size; after the first interval RSS ranged '
        '${_bytes(lo)}–${_bytes(hi)} '
        '(start ${_bytes(rssSamples.first.rss)}, '
        'end ${_bytes(last)}, peak ${_bytes(max(peakRss, ProcessInfo.maxRss))})';
  }
}

List<MapEntry<String, int>> _top(Map<String, int> counts, int n) {
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      if (byCount != 0) return byCount;
      return a.key.compareTo(b.key);
    });
  if (entries.length <= n) return entries;
  return entries.sublist(0, n);
}

String _pad(int n) => n.toString().padLeft(7);

String _ms(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '$ms ms';
  return '${(ms / 1000).toStringAsFixed(2)} s ($ms ms)';
}

String _bytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB ($n bytes)';
}
