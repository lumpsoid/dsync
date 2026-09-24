// Task 07876c spike: the Rust core (native/) receiving a tree inside the
// Flutter app, driven over rinf signals. Not part of the build. It starts a
// Rust server, prints its port and device id, waits for a transfer and
// prints every metric the server reports, TRANSFERS times over, into the same
// root: with TRANSFERS=2 the second push of the same tree is the overwrite
// pass.
//
//   flutter drive --profile -d <device> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/rust_spike_test.dart \
//     [--dart-define=ROOT=<dir>] [--dart-define=PORT=47670] \
//     [--dart-define=ALLOW=<peer id>|ANY] [--dart-define=WRITERS=16] \
//     [--dart-define=TRANSFERS=1]
//
// ROOT defaults to /storage/emulated/0/dsync-test/rust-spike on Android
// (under the app's All-files grant) and to a fresh temp dir elsewhere; files
// already there are overwritten, not cleared. ALLOW defaults to ANY. Then,
// each time it prints `ready`, push from the desktop with the id it printed
// (one id for every transfer of a run):
//
//   native/target/release/dsync-rs push <tree> --host <phone> \
//     --port 47670 --pin <id> [--order walk|spread]
//
// native/NOTES.md has the build steps and the numbers.
import 'dart:async';
import 'dart:io';

import 'package:dsync/app/rust/bindings/bindings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rinf/rinf.dart';

const _root = String.fromEnvironment('ROOT');
const _port = int.fromEnvironment('PORT', defaultValue: 47670);
const _allow = String.fromEnvironment('ALLOW', defaultValue: 'ANY');
const _writers = int.fromEnvironment('WRITERS', defaultValue: 16);
const _transfers = int.fromEnvironment('TRANSFERS', defaultValue: 1);

const _androidRoot = '/storage/emulated/0/dsync-test/rust-spike';

String _resolveRoot() {
  if (_root.isNotEmpty) return _root;
  if (Platform.isAndroid) return _androidRoot;
  return Directory.systemTemp.createTempSync('dsync-rust-spike-').path;
}

void _log(String line) => debugPrint('[rust-spike] $line');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('rust spike serve', (tester) async {
    await initializeRust(assignRustSignal);
    final root = _resolveRoot();
    for (var transfer = 1; transfer <= _transfers; transfer++) {
      await _serveOnce(root, '$transfer/$_transfers');
    }
  }, timeout: Timeout.none);
}

/// Serves one transfer into [root] and prints everything it reports.
Future<void> _serveOnce(String root, String label) async {
  var progressSignals = 0;
  TransferProgress? lastProgress;
  final progress = TransferProgress.rustSignalStream.listen((pack) {
    progressSignals++;
    lastProgress = pack.message;
  });
  final ready = ServeReady.rustSignalStream.first;
  final outcome = Completer<TransferDone>();
  final done = TransferDone.rustSignalStream.listen(
    (pack) => outcome.complete(pack.message),
  );
  final failed = ServeFailed.rustSignalStream.listen((pack) {
    final failure = pack.message;
    _log(
      'transfer $label failed: ${failure.message}  '
      'path ${failure.path ?? '-'}  stage ${failure.stage ?? '-'}  '
      'kind ${failure.ioKind ?? '-'}  os error ${failure.osCode ?? '-'}',
    );
    outcome.completeError(StateError(failure.message));
  });

  StartServe(
    root: root,
    port: _port,
    allowPeerId: _allow,
    writers: _writers,
  ).sendSignalToRust();
  final listening = (await ready).message;
  _log(
    'transfer $label ready port ${listening.port} id ${listening.deviceId} '
    'root $root allow $_allow writers $_writers',
  );

  try {
    final metrics = await outcome.future;
    _metricLines(metrics).forEach(_log);
    _log(
      'progress signals $progressSignals, last '
      '${lastProgress?.files ?? '-'} files ${lastProgress?.bytes ?? '-'} bytes',
    );
  } finally {
    await progress.cancel();
    await done.cancel();
    await failed.cancel();
  }
}

/// The server's report, in the lines `dsync-rs serve` prints.
List<String> _metricLines(TransferDone m) {
  String seconds(double? s) => s?.toStringAsFixed(3) ?? '-';
  final stages = m.stages
      .map(
        (s) =>
            '  ${s.name} ${s.count} ${s.meanMs.toStringAsFixed(3)} '
            '${s.totalSeconds.toStringAsFixed(3)}',
      )
      .join();
  return [
    'peer ${m.peerDeviceId}',
    'received ${m.files} files  '
        '${(m.bytes.toInt() / (1 << 20)).toStringAsFixed(1)} MiB in '
        '${m.wallSeconds.toStringAsFixed(2)} s  '
        '${m.mibPerSecond.toStringAsFixed(1)} MiB/s  '
        '${m.filesPerSecond.toStringAsFixed(0)} files/s  '
        'cpu ${m.cpuSeconds?.toStringAsFixed(2) ?? '-'} s  '
        '${m.cpuMsPerMib?.toStringAsFixed(1) ?? '-'} ms/MiB',
    'stages (count, mean ms, total s):$stages',
    'writers ${m.writers}  busy ${m.writersBusy.toStringAsFixed(2)}  '
        'queue wait mean ${m.queueWaitMeanMs.toStringAsFixed(3)} ms '
        'total ${m.queueWaitTotalSeconds.toStringAsFixed(3)} s',
    'cpu writers ${seconds(m.writerCpuSeconds)} s  '
        'rest ${seconds(m.otherCpuSeconds)} s',
  ];
}
