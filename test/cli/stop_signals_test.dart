import 'package:dsync/cli/exit_code.dart';
import 'package:dsync/cli/stop_signals.dart';
import 'package:test/test.dart';

void main() {
  group('trappableStopSignals (task 7ba6b5)', () {
    test('a POSIX host traps both SIGINT and SIGTERM', () {
      expect(trappableStopSignals(isWindows: false), [
        StopSignal.sigint,
        StopSignal.sigterm,
      ]);
    });

    test('Windows traps only SIGINT — dart:io cannot watch SIGTERM there', () {
      expect(trappableStopSignals(isWindows: true), [StopSignal.sigint]);
    });
  });

  group('StopSignal (SPEC §11.5)', () {
    test('carries 128 + signal number and the conventional name', () {
      expect(StopSignal.sigint.exitCode, 130);
      expect(StopSignal.sigint.label, 'SIGINT');
      expect(StopSignal.sigterm.exitCode, 143);
      expect(StopSignal.sigterm.label, 'SIGTERM');
    });
  });
}
