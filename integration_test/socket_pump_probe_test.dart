// Device measurement for task 4dc926 — which receiving socket stack holds a
// large peer:// pull on the phone to ~7.8 MiB/s. Not part of the build. The
// phone half of benchmark/socket_pump.dart: that file's header has the cases,
// how to read them, and the desktop half's command.
//
//   flutter drive --profile -d <serial> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/socket_pump_probe_test.dart \
//     [--dart-define=PORT=47470] [--dart-define=CASES=plain,raw,tls,adapter,tls-big]
//
// then, from the desktop, once the phone prints `listening`:
//
//   dart run benchmark/socket_pump.dart send --host 192.168.0.61
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../benchmark/socket_pump.dart';

const _port = int.fromEnvironment('PORT', defaultValue: defaultPumpPort);
const _cases = String.fromEnvironment(
  'CASES',
  defaultValue: 'plain,raw,tls,adapter,tls-big',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('socket pump probe', (tester) async {
    await receive(
      port: _port,
      cases: PumpCase.parse(_cases),
      log: (line) => debugPrint('[probe] $line'),
    );
  }, timeout: Timeout.none);
}
