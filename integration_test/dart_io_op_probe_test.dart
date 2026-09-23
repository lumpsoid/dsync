// Device measurement for task 4759eb — whether async dart:io file operations
// are served one at a time on the phone. Not part of the build.
//
// The apply's write path showed a lone `stat` or `setLastModified` at ~380 µs
// and each ~16x that under 16 workers, with the CPU mostly idle. This takes
// the Applier out: K loops, each awaiting one operation at a time over its
// share of [_files] existing files in app-private storage, against the same
// operation done synchronously. If K loops finish no sooner than one, the
// async round trip is the serial resource.
//
//   flutter drive --profile -d <id> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/dart_io_op_probe_test.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _files = int.fromEnvironment('FILES', defaultValue: 1600);
const _repeats = int.fromEnvironment('REPEATS', defaultValue: 3);
const _loops = [1, 4, 16];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dart:io op probe', (tester) async {
    final work = Directory('${Directory.systemTemp.path}/dsync-io-probe');
    if (work.existsSync()) work.deleteSync(recursive: true);
    work.createSync(recursive: true);
    final files = [
      for (var i = 0; i < _files; i++)
        File('${work.path}/f$i')..writeAsBytesSync(const [1, 2, 3]),
    ];
    final stamp = DateTime.fromMicrosecondsSinceEpoch(1700000000000000);

    final ops = <String, Future<void> Function(File)>{
      'stat': (file) => file.stat(),
      'setLastModified': (file) => file.setLastModified(stamp),
      'exists': (file) => file.exists(),
    };
    final syncOps = <String, void Function(File)>{
      'statSync': (file) => file.statSync(),
      'setLastModifiedSync': (file) => file.setLastModifiedSync(stamp),
      'existsSync': (file) => file.existsSync(),
    };

    final results = <String, Object>{};
    void report(String op, int loops, int repeat, Stopwatch clock) {
      final perOp = clock.elapsedMicroseconds / _files;
      _log(
        'RESULT op=$op loops=$loops repeat=$repeat '
        'ms=${clock.elapsedMilliseconds} usPerOp=${perOp.round()}',
      );
      results['$op-k$loops-r$repeat'] = perOp.round();
    }

    // Every repeat runs every case once, the order rotated per repeat so a
    // drift over the run does not land on one case.
    final cases = <Future<void> Function(int repeat)>[
      for (final MapEntry(key: name, value: op) in ops.entries)
        for (final loops in _loops)
          (repeat) async {
            final clock = Stopwatch()..start();
            await Future.wait([
              for (var k = 0; k < loops; k++)
                () async {
                  for (var i = k; i < files.length; i += loops) {
                    await op(files[i]);
                  }
                }(),
            ]);
            clock.stop();
            report(name, loops, repeat, clock);
          },
      for (final MapEntry(key: name, value: op) in syncOps.entries)
        (repeat) async {
          final clock = Stopwatch()..start();
          for (final file in files) {
            op(file);
          }
          clock.stop();
          report(name, 1, repeat, clock);
        },
    ];
    for (var repeat = 0; repeat < _repeats; repeat++) {
      for (var i = 0; i < cases.length; i++) {
        await cases[(i + repeat) % cases.length](repeat);
      }
    }

    work.deleteSync(recursive: true);
    binding.reportData = results;
  }, timeout: Timeout.none);
}

void _log(String line) => debugPrint('[bench] $line');
