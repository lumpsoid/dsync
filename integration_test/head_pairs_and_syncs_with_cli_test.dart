// The Flutter head over the real Rust core (plan phase 15): the app pairs
// with a Rust `dsync` on the same machine, which then serves a folder the
// app syncs with — through the head's own controllers and Run page, the
// hub, and the CLI's `agent --serve`. Linux only; not part of `flutter test`.
//
// Every piece of state lives in temp dirs: the app's core resolves its
// state and config under XDG_STATE_HOME / XDG_CONFIG_HOME (plus the
// `dsync` leaf), and the CLI gets `--state-dir`. Run from the repo root:
//
//   (cd native && cargo build -p dsync-cli)
//   work=$(mktemp -d)
//   XDG_STATE_HOME=$work/state XDG_CONFIG_HOME=$work/config \
//   flutter drive --profile -d linux \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/head_pairs_and_syncs_with_cli_test.dart \
//     --dart-define=DSYNC=$PWD/native/target/debug/dsync \
//     --dart-define=WORK=$work
//
// WORK must be a fresh, empty directory; the test refuses to start when
// XDG_STATE_HOME is not under it, so it can never touch a real state dir.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/models/entry_draft.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/core_link/core_channel.dart';
import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/features/pair_show/pair_show_controller.dart';
import 'package:dsync/app/features/pair_show/pair_show_view_state.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_page.dart';
import 'package:dsync/app/features/run/run_scope.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' show assignRustSignal;
import 'package:dsync/app/screen_wake.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:rinf/rinf.dart';

const _dsync = String.fromEnvironment('DSYNC');
const _work = String.fromEnvironment('WORK');

/// The port the CLI serves on: not the default, so a real agent on this
/// machine is never the one the app reaches.
const _servePort = 28791;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app pairs with a CLI agent and syncs a folder with it', (
    tester,
  ) async {
    _refuseRealState();
    final work = Directory(_work);
    final cliState = p.join(work.path, 'cli-state');
    final cliRoot = Directory(p.join(work.path, 'cli-root'))..createSync();
    final appRoot = Directory(p.join(work.path, 'app-root'))..createSync();
    const files = 12;
    for (var i = 0; i < files; i++) {
      File(p.join(appRoot.path, 'note-$i.txt')).writeAsStringSync('note $i\n');
    }

    await initializeRust(assignRustSignal);
    final app = AppController(
      CoreLink(const RinfCoreChannel()),
      supportDir: () async => null,
      now: DateTime.now,
    );
    appScope.setController(app);
    await app.bootstrap();
    expect(app.state.bootstrap, isA<AppBootstrapReady>());
    expect(
      (await app.dirs).stateDir,
      p.join(Platform.environment['XDG_STATE_HOME']!, 'dsync'),
    );

    // Pairing: the app shows its code, the CLI redeems it, the app's
    // operator confirms the id the CLI presented.
    final pairShow = PairShowController(
      app,
      bindAddress: () async => InternetAddress.loopbackIPv4,
    );
    final showing = pairShow.show(peerName: 'desktop');
    final waiting = await _until(
      tester,
      () => pairShow.state.status is PairShowWaiting,
      'the pairing code',
    ).then((_) => pairShow.state.status as PairShowWaiting);
    final accept = await Process.start(_dsync, [
      'pair',
      'accept',
      '--state-dir',
      cliState,
      '--name',
      'phone',
      waiting.offer.payloadLine,
    ]);
    final acceptErr = _collect(accept.stderr);
    await _until(
      tester,
      () => pairShow.state.status is PairShowConfirming,
      'the confirmation prompt',
    );
    pairShow.answerConfirmation(confirmed: true);
    await _until(
      tester,
      () => pairShow.state.status is PairShowPaired,
      'the pairing to be recorded',
    );
    await showing;
    expect(
      await accept.exitCode.timeout(const Duration(seconds: 10)),
      0,
      reason: acceptErr.toString(),
    );
    final desktop = app.state.devices.single;
    expect(desktop.name, 'desktop');

    // The CLI grants the app its folder and serves it.
    final grant = await Process.run(_dsync, [
      'pair',
      'grant',
      '--state-dir',
      cliState,
      'phone',
      cliRoot.path,
    ]);
    expect(grant.exitCode, 0, reason: '${grant.stderr}');
    final agent = await Process.start(_dsync, [
      'agent',
      '--serve',
      '--bind',
      '127.0.0.1',
      '--port',
      '$_servePort',
      '--state-dir',
      cliState,
    ]);
    addTearDown(agent.kill);
    final agentErr = _collect(agent.stderr);
    await _until(
      tester,
      () => agentErr.toString().contains('serving paired devices'),
      'the agent to listen',
    );

    // The sync, through the Run page: the plan sheet, accepted, then
    // progress and the summary.
    late SyncRunController run;
    runScope.setFactory(
      () => run = SyncRunController(app, screenWake: const _NoScreenWake()),
    );
    addTearDown(runScope.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: RunPage(
          request: RunRequest(
            target: DraftTarget(
              ProfileDraft(
                peerDeviceId: desktop.deviceId,
                entries: [
                  EntryDraft(localRoot: appRoot.path, remoteRoot: cliRoot.path),
                ],
              ),
            ),
            localRootPath: appRoot.path,
            deviceName: desktop.name,
            remoteRootPath: cliRoot.path,
            address: '127.0.0.1:$_servePort',
            dryRun: false,
          ),
          onDone: () {},
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const Key('run-sync-all-except-conflicts'))
          .evaluate()
          .isNotEmpty,
      'the review bar',
      failure: () => '${run.state.phase} ${agentErr.toString()}',
    );
    await tester.tap(find.byKey(const Key('run-sync-all-except-conflicts')));
    await _until(
      tester,
      () => run.state.phase is SyncRunFinished,
      'the summary',
      failure: () => '${run.state.phase} ${agentErr.toString()}',
    );
    await tester.pump();
    expect(find.byKey(const Key('run-summary')), findsOneWidget);
    final finished = run.state.phase as SyncRunFinished;
    expect(finished.applied, files);
    expect(finished.failed, 0);
    expect(run.state.progress?.completed, files);
    expect(run.state.progress?.total, files);
    for (var i = 0; i < files; i++) {
      expect(
        File(p.join(cliRoot.path, 'note-$i.txt')).readAsStringSync(),
        'note $i\n',
      );
    }
    expect(run.timings.value, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Nothing here may reach a real state dir: the drive command must point
/// the XDG dirs into [_work].
void _refuseRealState() {
  if (_dsync.isEmpty || _work.isEmpty) {
    fail(
      'pass --dart-define=DSYNC=<dsync binary> and --dart-define=WORK=<dir>',
    );
  }
  for (final variable in ['XDG_STATE_HOME', 'XDG_CONFIG_HOME']) {
    final value = Platform.environment[variable];
    if (value == null || !p.isWithin(_work, value)) {
      fail('$variable must be set under WORK ($_work), not "$value"');
    }
  }
}

/// Pumps until [done] holds, failing after a deadline sized to a local
/// run.
Future<void> _until(
  WidgetTester tester,
  bool Function() done,
  String what, {
  String Function()? failure,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what ${failure?.call() ?? ''}');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

StringBuffer _collect(Stream<List<int>> stream) {
  final buffer = StringBuffer();
  stream.transform(utf8.decoder).listen(buffer.write);
  return buffer;
}

class _NoScreenWake implements ScreenWake {
  const _NoScreenWake();

  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}
}
