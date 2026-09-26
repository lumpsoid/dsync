// The on-device half of the release check on an Android phone (task
// 83c7d4). Not part of `flutter test`, and not run by hand: the desktop
// driver `integration_test/phone_release_check.sh` builds the CLI, seeds
// the trees, starts this file with `flutter test -d <serial>` (twice: the
// `main` phase, then the `recover` phase after it force-stops the app),
// prompts the human steps, and compares the trees. Read its header first.
//
// What this file covers, against the real app build and a real desktop
// `dsync` over peer://:
//   (a) the All-files grant: a picked folder refused without it, the
//       settings page opened, then the same folder accepted with it;
//   (b) the system folder chooser's pick turned into a path;
//   (c) a sync the app starts against `dsync agent --serve`, and one the
//       desktop CLI starts against the app's Serve page;
//   (d) a run killed mid-apply, relaunched, its §7.6 run marker seen and
//       the run recovered.
//
// The driver and this file talk in two directions. This file prints
// `E2E|…` lines, which `flutter test` streams back to the driver's log;
// the driver answers by creating files under [_control], which this file
// can read once it holds All-files access (step a). Everything it writes on
// the phone is under [_testDir]; everything the app keeps is in its own
// container, which the driver's first step wipes by uninstalling.
import 'dart:io';

import 'package:dsync/app/app_bootstrap.dart';
import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/core_channel.dart';
import 'package:dsync/app/core_link/core_link.dart';
import 'package:dsync/app/core_link/models/conflict_choice.dart';
import 'package:dsync/app/core_link/models/profile_draft.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/features/pair_show/pair_show_controller.dart';
import 'package:dsync/app/features/pair_show/pair_show_view_state.dart';
import 'package:dsync/app/features/run/run_controller.dart';
import 'package:dsync/app/features/run/run_view_state.dart';
import 'package:dsync/app/features/run_setup/folder_picker.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/serve/serve_controller.dart';
import 'package:dsync/app/features/serve/serve_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' show assignRustSignal;
import 'package:dsync/app/screen_wake.dart';
import 'package:flutter/foundation.dart' show ValueListenable, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:rinf/rinf.dart';

/// `main` runs (a)–(c) and starts (d)'s run for the driver to kill;
/// `recover` is the relaunch after the kill.
const _phase = String.fromEnvironment('E2E_PHASE');

/// `host:port` of the desktop's `dsync agent --serve`.
const _desktopAddress = String.fromEnvironment('DESKTOP_ADDR');

/// The desktop folder (c)'s app-initiated sync pushes into, as granted.
const _desktopPushRoot = String.fromEnvironment('DESKTOP_PUSH_ROOT');

/// The desktop folder (d)'s killed run pulls from, as granted.
const _desktopBigRoot = String.fromEnvironment('DESKTOP_BIG_ROOT');

/// The only shared-storage folder this test touches. The driver creates
/// and wipes it; it is never a user folder.
const _testDir = '/storage/emulated/0/dsync-e2e';
final _appRoot = p.join(_testDir, 'app-root');
final _serveRoot = p.join(_testDir, 'serve-root');
final _appBig = p.join(_testDir, 'app-big');
final _control = p.join(_testDir, 'control');

/// The saved profile (d) runs, so the run marker has a profile to hang on.
const _killProfile = 'e2e-kill';

/// What the desktop CLI calls this phone (`pair accept --name`), and what
/// this phone calls the desktop.
const _desktopName = 'desktop';

/// Long enough for a person to find their way through a system screen.
const _humanWait = Duration(minutes: 15);

/// Long enough for a sync over Wi-Fi, short enough to not hang a session.
const _runWait = Duration(minutes: 10);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('release check on a phone: $_phase', (tester) async {
    _refuseWrongSetup();
    final status = ValueNotifier('Starting…');
    await tester.pumpWidget(_StatusScreen(status));

    await initializeRust(assignRustSignal);
    final app = AppController(
      CoreLink(const RinfCoreChannel()),
      supportDir: supportDirForThisDevice,
      now: DateTime.now,
    );
    appScope.setController(app);
    await app.bootstrap();
    expect(app.state.bootstrap, isA<AppBootstrapReady>());

    final e2e = _Session(tester, app, status);
    switch (_phase) {
      case 'main':
        await e2e.allFilesAndPick();
        final desktop = await e2e.pair();
        await e2e.appInitiates(desktop);
        await e2e.cliInitiates(desktop);
        await e2e.runToBeKilled(desktop);
      case 'recover':
        await e2e.recover();
    }
  }, timeout: const Timeout(Duration(minutes: 90)));
}

void _refuseWrongSetup() {
  if (!Platform.isAndroid) fail('this test runs on an Android device only');
  if (_phase != 'main' && _phase != 'recover') {
    fail('pass --dart-define=E2E_PHASE=main or =recover');
  }
  for (final (name, value) in [
    ('DESKTOP_ADDR', _desktopAddress),
    ('DESKTOP_PUSH_ROOT', _desktopPushRoot),
    ('DESKTOP_BIG_ROOT', _desktopBigRoot),
  ]) {
    if (value.isEmpty) fail('pass --dart-define=$name=…; see the driver');
  }
}

/// One phase's steps, over the one app they share.
class _Session {
  _Session(this.tester, this.app, this.status);

  final WidgetTester tester;
  final AppController app;
  final ValueNotifier<String> status;

  /// (a) and (b), through Run setup's own pick flow and the real platform
  /// picker, which the person drives.
  Future<void> allFilesAndPick() async {
    final picker = _RecordingPicker(PlatformFolderPicker.forThisHost());
    final setup = RunSetupController(app, picker: picker);

    _say(
      'a1-chooser',
      'Pick dsync-e2e/app-root in the chooser. Then LEAVE All-files access '
          'OFF and go back.',
    );
    await setup.pickLocalFolder();
    if (picker.lastPicked == null) _fail('a', 'the chooser was dismissed');
    if (picker.lastPicked != _appRoot) {
      _fail('b', 'the chooser answered ${picker.lastPicked}, not $_appRoot');
    }
    final refusal = setup.state.folderAccessError;
    if (refusal == null) {
      _fail(
        'a',
        'the folder was taken without All-files access, so the refusal '
            'path never ran (grant already there, or an old Android)',
      );
    }
    if (picker.lastRequestAnswer != false) {
      _fail('a', 'the grant request answered ${picker.lastRequestAnswer}');
    }
    _mark('a|probe-refused|${_oneLine(refusal)}');

    _say(
      'a2-settings',
      'Settings is open: turn on All-files access for dsync, then come '
          'back to this screen.',
    );
    await setup.openAccessSettings();
    await _until(
      () async => await app.core.checkFolder(_appRoot) == null,
      'All-files access for $_appRoot',
      within: _humanWait,
      step: 'a',
    );
    _mark('a|granted');

    _say('b-chooser', 'Pick dsync-e2e/app-root in the chooser once more.');
    await setup.pickLocalFolder();
    if (setup.state.folderAccessError case final error?) {
      _fail('b', 'the granted folder was refused: ${_oneLine(error)}');
    }
    if (setup.state.localRoot != _appRoot) {
      _fail('b', 'the form holds ${setup.state.localRoot}, not $_appRoot');
    }
    _mark('b|ok|${setup.state.localRoot}');
    setup.dispose();
  }

  /// Shows a pairing code for the driver's `dsync pair accept`, confirms
  /// the id it presents, and answers the desktop as this app lists it.
  Future<({String deviceId, String name})> pair() async {
    final pairShow = PairShowController(app, bindAddress: _lanAddress);
    final showing = pairShow.show(peerName: _desktopName);
    await _until(
      () async => pairShow.state.status is PairShowWaiting,
      'the pairing code',
      within: const Duration(seconds: 30),
      step: 'c',
    );
    final offer = (pairShow.state.status as PairShowWaiting).offer;
    _say('pair', 'Pairing with the desktop at ${offer.address}…');
    _mark('pair|${offer.payloadLine}');
    await _until(
      () async => pairShow.state.status is PairShowConfirming,
      'the desktop to redeem the code',
      within: const Duration(minutes: 2),
      step: 'c',
      failure: () => '${pairShow.state.status}',
    );
    pairShow.answerConfirmation(confirmed: true);
    await _until(
      () async => pairShow.state.status is PairShowPaired,
      'the pairing to be recorded',
      within: const Duration(seconds: 30),
      step: 'c',
      failure: () => '${pairShow.state.status}',
    );
    await showing;
    pairShow.dispose();
    final desktop = app.state.devices.single;
    _mark('paired|${desktop.deviceId}');
    return (deviceId: desktop.deviceId, name: desktop.name);
  }

  /// (c), app side: this phone's app-root pushed to the desktop's agent.
  Future<void> appInitiates(({String deviceId, String name}) desktop) async {
    await _awaitControl('agent-serving', step: 'c');
    final files = Directory(_appRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .length;
    _say('c1', 'Syncing app-root to the desktop…');
    final run = await _run(
      RunRequest(
        target: DraftTarget(
          ProfileDraft(
            localRoot: _appRoot,
            peerDeviceId: desktop.deviceId,
            remoteRoot: _desktopPushRoot,
          ),
        ),
        localRootPath: _appRoot,
        deviceName: desktop.name,
        remoteRootPath: _desktopPushRoot,
        address: _desktopAddress,
        dryRun: false,
      ),
      step: 'c',
    );
    await run.acceptAll();
    final finished = await _finished(run, step: 'c');
    if (finished.failed != 0 || finished.applied != files) {
      _fail(
        'c',
        'app-initiated run applied ${finished.applied} of $files, '
            'failed ${finished.failed}',
      );
    }
    run.dispose();
    _mark('c1|done|applied=${finished.applied}');
  }

  /// (c), desktop side: this phone serves serve-root until the driver's
  /// CLI sync is done with it.
  Future<void> cliInitiates(({String deviceId, String name}) desktop) async {
    final refused = await app.grantRoot(desktop.deviceId, _serveRoot);
    if (refused != null) _fail('c', 'granting $_serveRoot: $refused');
    final serve = ServeController(
      app,
      bindAddress: _lanAddress,
      screenWake: const PlatformScreenWake(),
    );
    await serve.start();
    await _until(
      () async => serve.state.status is ServeListening,
      'Serve to listen',
      within: const Duration(seconds: 30),
      step: 'c',
      failure: () => '${serve.state.status}',
    );
    final address = (serve.state.status as ServeListening).address;
    _say('c2', 'Serving serve-root on $address for the desktop…');
    _mark('serving|$address');
    await _awaitControl('c2-done', step: 'c', within: _runWait);
    _mark('c2|sessions|${_oneLine(serve.state.sessions.join(' / '))}');
    await serve.stop();
    serve.dispose();
  }

  /// (d), before the kill: a saved profile's run pulling the desktop's big
  /// tree, reported the moment it is applying, then left to be killed.
  Future<void> runToBeKilled(({String deviceId, String name}) desktop) async {
    await app.saveProfile(
      _killProfile,
      ProfileDraft(
        localRoot: _appBig,
        peerDeviceId: desktop.deviceId,
        remoteRoot: _desktopBigRoot,
      ),
    );
    _say('d-run', 'Pulling the big tree; the desktop will kill this app.');
    final run = await _run(_profileRequest(desktop.name), step: 'd');
    await run.acceptAll();
    await _until(
      () async => (run.state.progress?.completed ?? 0) > 0,
      'the apply to start',
      within: _runWait,
      step: 'd',
      failure: () => '${run.state.phase}',
    );
    final progress =
        run.state.progress ?? _fail('d', 'applying without progress');
    _mark('d|applying|${progress.completed}/${progress.total}');
    await _until(
      () async => run.state.phase is SyncRunFinished,
      'the force-stop',
      within: _runWait,
      step: 'd',
    );
    _fail('d', 'the run finished before the driver killed it');
  }

  /// (d), after the relaunch: the marker is on the profile's row, and
  /// running the profile again converges it.
  Future<void> recover() async {
    final before = await _killProfileEntry();
    if (!before.lastRunUnfinished) {
      _fail('d', 'no run marker on $_killProfile after the kill');
    }
    _mark('d|marker|true');
    _say('d-recover', 'Running $_killProfile again…');
    final deviceName =
        before.peerName ?? _fail('d', 'the desktop is no longer paired');
    final run = await _run(_profileRequest(deviceName), step: 'd');
    // A file torn by the kill is a conflict labelled interrupted (§7.6);
    // the desktop's copy is the one that finished.
    var interrupted = 0;
    for (final conflict in run.state.conflicts) {
      if (conflict.local.status == SyncRunSideStatus.interrupted) {
        interrupted++;
      }
      if (!conflict.offered.contains(ConflictChoice.keepB)) {
        _fail('d', '${conflict.path} does not offer the desktop\'s copy');
      }
      await run.resolveConflict(conflict.index, ConflictChoice.keepB);
    }
    await run.confirm();
    final finished = await _finished(run, step: 'd');
    run.dispose();
    if (finished.failed != 0 || finished.conflicts != 0) {
      _fail(
        'd',
        'the recovery run failed ${finished.failed} and left '
            '${finished.conflicts} conflicts',
      );
    }
    final after = await _killProfileEntry();
    if (after.lastRunUnfinished) {
      _fail('d', 'the run marker is still there after the recovery run');
    }
    _mark(
      'd|recovered|applied=${finished.applied} '
      'interrupted=$interrupted',
    );
    _say('done', 'Done. The desktop compares the trees now.');
  }

  RunRequest _profileRequest(String deviceName) => RunRequest(
    target: const SavedProfileTarget(_killProfile),
    localRootPath: _appBig,
    deviceName: deviceName,
    remoteRootPath: _desktopBigRoot,
    address: _desktopAddress,
    dryRun: false,
  );

  Future<HeadProfile> _killProfileEntry() async {
    final profile = (await app.core.listProfiles())
        .whereType<HeadProfile>()
        .where((profile) => profile.name == _killProfile)
        .firstOrNull;
    if (profile == null) _fail('d', 'no saved profile $_killProfile');
    return profile;
  }

  /// Starts [request] and waits for its review, riding out a replica the
  /// killed run's session still holds.
  Future<SyncRunController> _run(
    RunRequest request, {
    required String step,
  }) async {
    final run = SyncRunController(app, screenWake: const PlatformScreenWake());
    await run.start(request);
    final deadline = DateTime.now().add(_runWait);
    while (run.state.phase is! SyncRunAwaitingDecisions) {
      final phase = run.state.phase;
      if (phase is SyncRunFailed) _fail(step, 'run failed: ${phase.message}');
      if (phase is SyncRunFinished) {
        _fail(step, 'run finished with nothing to review: $phase');
      }
      if (DateTime.now().isAfter(deadline)) {
        _fail(step, 'timed out waiting for the review ($phase)');
      }
      if (phase is SyncRunReplicaBusy) {
        await tester.pump(const Duration(seconds: 3));
        await run.resume();
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    return run;
  }

  Future<SyncRunFinished> _finished(
    SyncRunController run, {
    required String step,
  }) async {
    await _until(
      () async =>
          run.state.phase is SyncRunFinished ||
          run.state.phase is SyncRunFailed,
      'the run to finish',
      within: _runWait,
      step: step,
    );
    final phase = run.state.phase;
    if (phase is! SyncRunFinished) _fail(step, 'run ended as $phase');
    return phase;
  }

  Future<void> _awaitControl(
    String name, {
    required String step,
    Duration within = const Duration(minutes: 5),
  }) => _until(
    () async => File(p.join(_control, name)).exists(),
    'the desktop driver ($name)',
    within: within,
    step: step,
  );

  /// Pumps until [done] holds, failing [step] after [within].
  Future<void> _until(
    Future<bool> Function() done,
    String what, {
    required Duration within,
    required String step,
    String Function()? failure,
  }) async {
    final deadline = DateTime.now().add(within);
    while (!await done()) {
      if (DateTime.now().isAfter(deadline)) {
        _fail(step, 'timed out waiting for $what ${failure?.call() ?? ''}');
      }
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// Tells both the driver and the person at the phone what is next.
  void _say(String step, String text) {
    status.value = text;
    _mark('step|$step');
  }
}

/// One line for the driver's log; see the file header.
void _mark(String line) => debugPrint('E2E|$line');

Never _fail(String step, String reason) {
  _mark('fail|$step|${_oneLine(reason)}');
  fail('($step) $reason');
}

String _oneLine(String text) => text.replaceAll('\n', ' ');

/// The phone's Wi-Fi address, so the pairing payload and Serve advertise
/// the address the desktop can reach rather than the first interface the
/// core finds (mobile data, a VPN). Every interface when there is none.
Future<InternetAddress> _lanAddress() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  for (final interface in interfaces) {
    if (interface.name.startsWith('wlan')) return interface.addresses.first;
  }
  return InternetAddress.anyIPv4;
}

/// The real platform picker, with what it answered kept for the checks.
final class _RecordingPicker implements FolderPicker {
  _RecordingPicker(this._picker);

  final FolderPicker _picker;
  String? lastPicked;
  bool? lastRequestAnswer;

  @override
  Future<String?> pick() async => lastPicked = await _picker.pick();

  @override
  Future<bool> requestAccess() async =>
      lastRequestAnswer = await _picker.requestAccess();

  @override
  Future<void> openSettings() => _picker.openSettings();
}

/// What the person at the phone reads while the driver waits on them.
class _StatusScreen extends StatelessWidget {
  const _StatusScreen(this.status);

  final ValueListenable<String> status;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder(
            valueListenable: status,
            builder: (context, text, _) => Text(
              'dsync release check\n\n$text',
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
      ),
    ),
  );
}
