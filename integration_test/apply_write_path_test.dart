// Device measurement for task 58d609 — §7.2's write path against writing in
// place behind a mark (SPEC §7.6), through the real `Applier` rather than
// `storage_probe.c`'s syscalls. Not part of the build.
//
// Pulls a tree shaped like §5.3's (its mean file size, `FILES` of them) from the app's
// cache directory, on the block device, into `/storage/emulated/0`, which is
// FUSE — so the source costs next to nothing and the figure is the
// destination's. Both replicas are local agents: no link, no protocol, only
// the apply. The same file runs against trunk and against the branch; which
// one it was is `--dart-define=BUILD=...`.
//
//   adb shell appops set --uid com.example.dsync MANAGE_EXTERNAL_STORAGE allow
//   flutter drive --profile -d <id> --dart-define=BUILD=branch \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/apply_write_path_test.dart
//
// The apply is timed whole, so on the branch the marks' exchange and fsync
// are inside the figure, as the task asks.
import 'dart:io';
import 'dart:math';

import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/dsync_core/archive/jsonl_archive_store.dart';
import 'package:dsync/dsync_core/lock/replica_lock.dart';
import 'package:dsync/dsync_core/models/archive.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/reconcile/reconciler.dart';
import 'package:dsync/dsync_core/scan/scan_exchange.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _build = String.fromEnvironment('BUILD', defaultValue: 'unnamed');

/// §5.3's tree is 14,471 files; per-file cost is flat in the count, so a
/// tenth of it reads the same figure in a tenth of the time.
const _files = int.fromEnvironment('FILES', defaultValue: 1500);
const _meanBytes = 13007; // §5.3's 179.5 MiB / 14,471
const _filesPerDir = 30;
const _destRoot = '/storage/emulated/0/dsync-bench';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('apply write path, $_build', (tester) async {
    final results = <String, Object>{};
    final work = Directory('${Directory.systemTemp.path}/dsync-bench');
    if (work.existsSync()) work.deleteSync(recursive: true);
    final source = Directory('${work.path}/source')
      ..createSync(recursive: true);

    final generated = Stopwatch()..start();
    final totalBytes = _generate(source);
    _log('generated $_files files, $totalBytes B in ${generated.elapsed}');

    await _awaitWritable();

    final logA = File('${work.path}/a.jsonl');
    final agentA = LocalAgent(
      rootPath: source.path,
      archiveStore: JsonlArchiveStore(logA, _header(source.path)),
      replicaLock: ReplicaLock(File('${work.path}/a.lock')),
    );

    final dest = Directory('$_destRoot/dest');
    final logB = File('${work.path}/b.jsonl');

    /// One timed apply of whatever A holds onto B, as it stands.
    Future<void> pull(String pass, int concurrency) async {
      final agentB = LocalAgent(
        rootPath: dest.path,
        archiveStore: JsonlArchiveStore(logB, _header(dest.path)),
        replicaLock: ReplicaLock(File('${work.path}/b.lock')),
      );
      final scans = await exchangeScans(
        await agentA.scan(RuleSet()),
        await agentB.scan(RuleSet()),
      );
      final plan = Reconciler().reconcile(scans.onA, scans.onB);
      final copies = plan.actions
          .where((action) => action.type == ActionType.copyAtoB)
          .length;

      final applied = Stopwatch()..start();
      final result = await Applier(concurrency: concurrency)
          .apply(plan, scans.onA, scans.onB, agentA, agentB);
      applied.stop();
      await agentA.unlock();
      await agentB.unlock();

      final landed = await dest
          .list(recursive: true)
          .where((entity) => entity is File)
          .length;
      final perFileUs = applied.elapsedMicroseconds ~/ copies;
      _log(
        'RESULT build=$_build pass=$pass concurrency=$concurrency '
        'copies=$copies applied=${result.applied.length} '
        'failed=${result.failed.length} landed=$landed '
        'applyMs=${applied.elapsedMilliseconds} usPerFile=$perFileUs',
      );
      results['$pass-c$concurrency'] = {
        'applyMs': applied.elapsedMilliseconds,
        'usPerFile': perFileUs,
        'copies': copies,
        'failed': result.failed.length,
        'landed': landed,
        if (result.failed.isNotEmpty)
          'firstError': result.failed.first.error.toString(),
      };
    }

    Future<void> clear() async {
      final cleared = Stopwatch()..start();
      if (dest.existsSync()) await dest.delete(recursive: true);
      dest.createSync(recursive: true);
      if (logB.existsSync()) logB.deleteSync();
      _log('cleared the destination in ${cleared.elapsed}');
    }

    // A fresh pull creates every file whatever the write path does; an
    // overwrite is where the two differ by the rename alone. The last fresh
    // pull is what the overwrites write over.
    for (final concurrency in [1, 16]) {
      await clear();
      await pull('fresh', concurrency);
    }
    for (final (round, concurrency) in [(1, 16), (2, 1)]) {
      _modify(source, round);
      await pull('overwrite', concurrency);
    }

    await Directory(_destRoot).delete(recursive: true);
    work.deleteSync(recursive: true);
    binding.reportData = {'build': _build, ...results};
  }, timeout: Timeout.none);
}

ArchiveHeader _header(String root) => ArchiveHeader(
  schemaVersion: JsonlArchiveStore.schemaVersion,
  profileId: 'bench',
  rootPath: root,
);

/// A tree of [_files] files averaging [_meanBytes], [_filesPerDir] to a
/// directory, sizes drawn exponentially so most are small and a few are
/// large — the same shape, not the same bytes, as §5.3's. Seeded, so trunk
/// and the branch write identical trees.
int _generate(Directory root) {
  final random = Random(58609);
  final buffer = Uint8List(1 << 20);
  for (var i = 0; i < buffer.length; i++) {
    buffer[i] = random.nextInt(256);
  }
  var total = 0;
  for (var i = 0; i < _files; i++) {
    final dir = Directory(
      '${root.path}/d${i ~/ (_filesPerDir * _filesPerDir)}/'
      'd${(i ~/ _filesPerDir) % _filesPerDir}',
    );
    if (i % _filesPerDir == 0) dir.createSync(recursive: true);
    final size = min(
      buffer.length,
      max(1, (-log(1 - random.nextDouble()) * _meanBytes).round()),
    );
    final offset = random.nextInt(buffer.length - size + 1);
    File('${dir.path}/f$i.bin')
        .writeAsBytesSync(Uint8List.sublistView(buffer, offset, offset + size));
    total += size;
  }
  return total;
}

/// Rewrites every file under [root] with bytes it has not held before, at
/// the same size, so the next pull copies each one over its old self.
void _modify(Directory root, int round) {
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File) continue;
    final bytes = entity.readAsBytesSync();
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (bytes[i] + round) & 0xFF;
    }
    entity.writeAsBytesSync(bytes);
  }
}

/// Waits for the All-files grant, which `adb shell appops` gives only once
/// the install has put the package there.
Future<void> _awaitWritable() async {
  for (var attempt = 0; attempt < 120; attempt++) {
    try {
      Directory(_destRoot).createSync(recursive: true);
      File('$_destRoot/.probe')
        ..writeAsStringSync('x')
        ..deleteSync();
      return;
    } on FileSystemException {
      if (attempt % 10 == 0) _log('waiting for the All-files grant');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  throw StateError('$_destRoot never became writable');
}

void _log(String line) => debugPrint('[bench] $line');
