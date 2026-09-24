// Task 07876c spike: the Rust core (native/) receiving a tree inside the
// Flutter app, driven over rinf signals. Not part of the build. It starts a
// Rust server, prints its port and device id, waits for one transfer and
// prints the server's metrics and how many progress signals Dart saw.
//
//   flutter drive --profile -d <device> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/rust_spike_test.dart \
//     [--dart-define=ROOT=<dir>] [--dart-define=PORT=47670] \
//     [--dart-define=ALLOW=<peer id>|ANY]
//
// ROOT defaults to /storage/emulated/0/dsync-test/rust-spike on Android
// (under the app's All-files grant) and to a fresh temp dir elsewhere; files
// already there are overwritten, not cleared. ALLOW defaults to ANY. Then,
// once it prints `ready`, push from the desktop with the id it printed:
//
//   native/target/release/dsync-rs push <tree> --host <phone> \
//     --port 47670 --pin <id>
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
    final failed = ServeFailed.rustSignalStream.listen(
      (pack) => outcome.completeError(StateError(pack.message.message)),
    );

    StartServe(root: root, port: _port, allowPeerId: _allow).sendSignalToRust();
    final listening = (await ready).message;
    _log(
      'ready port ${listening.port} id ${listening.deviceId} '
      'root $root allow $_allow',
    );

    try {
      final metrics = await outcome.future;
      _log('peer ${metrics.peerDeviceId}');
      _log(
        'received ${metrics.files} files  '
        '${(metrics.bytes.toInt() / (1 << 20)).toStringAsFixed(1)} MiB in '
        '${metrics.wallSeconds.toStringAsFixed(2)} s  '
        '${metrics.mibPerSecond.toStringAsFixed(1)} MiB/s  '
        '${metrics.filesPerSecond.toStringAsFixed(0)} files/s  '
        'cpu ${metrics.cpuSeconds?.toStringAsFixed(2) ?? '-'} s  '
        '${metrics.cpuMsPerMib?.toStringAsFixed(1) ?? '-'} ms/MiB',
      );
      _log(
        'progress signals $progressSignals, last '
        '${lastProgress?.files ?? '-'} files ${lastProgress?.bytes ?? '-'} bytes',
      );
    } finally {
      await progress.cancel();
      await done.cancel();
      await failed.cancel();
    }
  }, timeout: Timeout.none);
}
