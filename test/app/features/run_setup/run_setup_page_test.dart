import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/models/run_target.dart';
import 'package:dsync/app/features/run_setup/run_setup_controller.dart';
import 'package:dsync/app/features/run_setup/run_setup_page.dart';
import 'package:dsync/app/features/run_setup/run_setup_scope.dart';
import 'package:dsync/app/features/run_setup/run_setup_view_state.dart';
import 'package:dsync/app/run_request.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../../support/fake_folder_picker.dart';
import '../../support/fake_head.dart';

/// Rendering tests for the Run setup page, driven the way the scope
/// contract in `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. The page's `initState`
/// calls `load`, which asks the core — a [FakeHub] here — so every
/// test first waits for it under `runAsync`, then writes the case it is about into the view
/// state as the controller would.
void main() {
  late Directory tempDir;
  late FakeHub core;
  late AppController app;
  late RunSetupController controller;
  late FakeFolderPicker picker;
  final desktop = pairedDevice(deviceId: 'desk-id', name: 'desktop');
  final started = <RunRequest>[];
  var saved = 0;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('run_setup_page_test');
    core = FakeHub()
      ..reply<wire.CoreCommandListDevices>(devicesReply([desktop]));
    app = fakeApp(core);
    picker = FakeFolderPicker();
    controller = RunSetupController(app, picker: picker);
    appScope.setController(app);
    runSetupScope.setController(controller);
    started.clear();
    saved = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(runSetupScope.reset);
  tearDown(() => controller.dispose());
  tearDown(() => tempDir.delete(recursive: true));

  /// Waits, in real time, for the controller to reach the state [done]
  /// names — by listening, not by sampling. Every `record*` on the view
  /// state is synchronous, so by the time a notification makes [done] true
  /// the write has landed and nothing of that operation is still in flight.
  ///
  /// Each call site says what it is waiting for, which is what keeps this
  /// from being a sleep: a condition that never holds fails the test with
  /// [what] in the message instead of hanging it.
  Future<void> settleUntil(bool Function() done, {required String what}) async {
    if (done()) return;
    final settled = Completer<void>();
    void check() {
      if (done() && !settled.isCompleted) settled.complete();
    }

    controller.state.addListener(check);
    try {
      await settled.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('timed out waiting for $what'),
      );
    } finally {
      controller.state.removeListener(check);
    }
  }

  /// The visit has finished loading, either way it went: `load` records the
  /// peer last, so leaving [RunSetupPeerLoading] is the whole of it.
  Future<void> loaded() => settleUntil(
    () => controller.state.peer is! RunSetupPeerLoading,
    what: 'the page to load',
  );

  /// Pumps the page over [source] and waits, in real time, for `load` to
  /// finish. Bounded so a regression fails rather than hangs. The viewport
  /// is made tall enough for the whole form: a `ListView` builds only what
  /// is on screen, and the button is last.
  Future<void> pumpLoaded(WidgetTester tester, {RunSetupSource? source}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RunSetupPage(
            source: source ?? RunSetupFromDevice(desktop.deviceId),
            onStart: started.add,
            onSaved: () => saved++,
          ),
        ),
      );
      await loaded();
    });
    await tester.pump();
  }

  /// Taps the pick button and lets the chooser, the probe and the grant —
  /// all real async work — finish, up to the state [until] names: the
  /// folder taken as the local root, or the refusal that kept it out.
  Future<void> pickFolder(
    WidgetTester tester, {
    required bool Function() until,
    required String what,
  }) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('run-setup-pick-folder')));
      await settleUntil(until, what: what);
    });
    await tester.pump();
  }

  /// Opens the form's disclosure. The optional per-run choices are folded
  /// away under the required pair, so a test that drives them asks first.
  Future<void> openDisclosure(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  bool startEnabled(WidgetTester tester) => tester
      .widget<FilledButton>(find.byKey(const Key('run-setup-start')))
      .enabled;

  testWidgets('loading: a progress indicator and no form', (tester) async {
    // Inside `runAsync`, like `pumpLoaded`.
    //
    // The frame `pumpWidget` renders is `load`'s first state, recorded
    // synchronously before its first `await` — and nothing rebuilds the
    // tree until the next pump, which these expectations do not perform.
    // So the spinner is what is on screen, without racing the load.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RunSetupPage(
            source: RunSetupFromDevice(desktop.deviceId),
            onStart: started.add,
            onSaved: () => saved++,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('run-setup-start')), findsNothing);
      // Let `load` finish before the tree is torn down: a write landing on
      // a disposed view state fails whichever test is running by then.
      await loaded();
    });
  });

  testWidgets('loading: the spinner says what it is waiting on', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RunSetupPage(
            source: RunSetupFromDevice(desktop.deviceId),
            onStart: started.add,
            onSaved: () => saved++,
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byType(CircularProgressIndicator)),
        isSemantics(label: 'Loading the device'),
      );
      semantics.dispose();
      await loaded();
    });
  });

  testWidgets('missing: the message instead of the form', (tester) async {
    await pumpLoaded(tester, source: const RunSetupFromDevice('dead:beef'));

    expect(find.textContaining('dead:beef'), findsOneWidget);
    expect(find.byKey(const Key('run-setup-start')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('loaded: the device name, every field, the switch off, and '
      'an enabled button', (tester) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-options');

    // The device is named by the section its folder belongs to, not by a
    // line of its own.
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('On desktop'), findsOneWidget);
    for (final key in const [
      'run-setup-local-folder',
      'run-setup-pick-folder',
      'run-setup-remote-root',
      'run-setup-address',
      'run-setup-dry-run',
      'run-setup-profile-name',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('run-setup-dry-run')))
          .value,
      isFalse,
    );
    expect(startEnabled(tester), isTrue);
    expect(find.textContaining('dsync pair grant'), findsOneWidget);
    expect(find.textContaining('has not granted this device'), findsNothing);
  });

  testWidgets('a blank form is Run setup, and saving offers a profile', (
    tester,
  ) async {
    await pumpLoaded(tester);

    expect(find.text('Run setup'), findsOneWidget);
    expect(find.text('Save profile'), findsOneWidget);
  });

  testWidgets('an edit says which profile it is about to write back over', (
    tester,
  ) async {
    core.reply<wire.CoreCommandListProfiles>(
      profilesReply([
        headProfile(name: 'weekly', peerDeviceId: desktop.deviceId),
      ]),
    );

    await pumpLoaded(tester, source: const RunSetupFromProfile('weekly'));

    // Navigated into from the home list, this page *is* the profile — so
    // it is titled as one, and the name is the field that says which.
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Run setup'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('run-setup-profile-name')))
          .controller
          ?.text,
      'weekly',
    );
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.text('Save profile'), findsNothing);
  });

  testWidgets('a profile whose last run did not finish is warned about '
      'before it runs again (task 99f404)', (tester) async {
    core.reply<wire.CoreCommandListProfiles>(
      profilesReply([
        headProfile(
          name: 'weekly',
          peerDeviceId: desktop.deviceId,
          lastRunUnfinished: true,
        ),
      ]),
    );

    await pumpLoaded(tester, source: const RunSetupFromProfile('weekly'));

    expect(
      find.byKey(const Key('run-setup-last-run-unfinished')),
      findsOneWidget,
    );
  });

  testWidgets('the folder is shown as a value, and the button beside it '
      'says whether there is one to change', (tester) async {
    await pumpLoaded(tester);
    expect(find.text('No folder chosen'), findsOneWidget);
    expect(find.text('Pick a folder…'), findsOneWidget);

    controller.state.updateEntry(
      0,
      (entry) => RunEntryForm(kind: entry.kind, localRoot: '/sdcard/photos'),
    );
    await tester.pump();

    expect(find.text('/sdcard/photos'), findsOneWidget);
    expect(find.text('No folder chosen'), findsNothing);
    expect(find.text('Pick a folder…'), findsNothing);
    expect(find.text('Change'), findsOneWidget);
  });

  testWidgets('the pick button shows the folder the chooser returned', (
    tester,
  ) async {
    final picked = '${tempDir.path}/elsewhere/camera';
    Directory(picked).createSync(recursive: true);
    picker.onPick = () => picked;
    await pumpLoaded(tester);

    await pickFolder(
      tester,
      until: () => controller.state.entries[0].localRoot == picked,
      what: 'the picked folder to become the local root',
    );

    expect(picker.pickCount, 1);
    expect(find.text(picked), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a folder the head cannot use is a snackbar with a way to fix '
      'it, and the form is untouched', (tester) async {
    final refused = '${tempDir.path}/elsewhere/no-such-tree';
    picker.onPick = () => refused;
    core.reply<wire.CoreCommandCheckFolder>(
      wire.ReplyResultFolderChecked(refusal: 'dsync cannot use $refused.'),
    );
    await pumpLoaded(tester);

    await pickFolder(
      tester,
      until: () => controller.state.folderAccessError != null,
      what: 'the folder to be refused',
    );

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('no-such-tree'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.text('No folder chosen'),
      findsOneWidget,
      reason: 'a refusal falls back to nothing: there is no other folder',
    );

    // The snackbar is still sliding in; its action is not hittable until
    // that animation has run.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Settings'));
    expect(picker.openSettingsCount, 1);
  });

  group('back from Settings (task 65e723)', () {
    /// The platform's own sequences, one state at a time — the way
    /// `AppLifecycleListener` expects them, as the Run page's tests drive
    /// it.
    const away = [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ];
    const back = [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ];

    void drive(WidgetTester tester, List<AppLifecycleState> states) {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    int checks() => core.sent<wire.CoreCommandCheckFolder>().length;

    late String refused;

    /// A folder refused by the pick and, when [openSettings], its
    /// snackbar's Settings tapped — and, when [leave], the app gone to it.
    Future<void> refuseThenOpenSettings(
      WidgetTester tester, {
      bool openSettings = true,
      bool leave = true,
    }) async {
      refused = '${tempDir.path}/elsewhere/sdcard';
      picker.onPick = () => refused;
      core.reply<wire.CoreCommandCheckFolder>(
        wire.ReplyResultFolderChecked(refusal: 'dsync cannot use $refused.'),
      );
      await pumpLoaded(tester);
      await pickFolder(
        tester,
        until: () => controller.state.folderAccessError != null,
        what: 'the folder to be refused',
      );
      if (!openSettings) return;
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Settings'));
      await tester.pump(const Duration(seconds: 1));
      if (!leave) return;
      drive(tester, away);
      await tester.pump();
    }

    testWidgets('with the grant given, the refused folder is checked again '
        'and shown as the chosen one', (tester) async {
      await refuseThenOpenSettings(tester);
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: null),
      );

      await tester.runAsync(() async {
        drive(tester, back);
        await settleUntil(
          () => controller.state.entries[0].localRoot == refused,
          what: 'the re-checked folder to become the local root',
        );
      });
      await tester.pump(const Duration(seconds: 1));

      expect(find.text(refused), findsOneWidget);
      expect(find.text('No folder chosen'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(picker.pickCount, 1);
    });

    testWidgets('still refused, the refusal is shown again with its way out', (
      tester,
    ) async {
      await refuseThenOpenSettings(tester);
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: 'still not granted'),
      );

      await tester.runAsync(() async {
        drive(tester, back);
        await settleUntil(
          () => controller.state.folderAccessError == 'still not granted',
          what: 'the re-check to refuse again',
        );
      });
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('still not granted'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('No folder chosen'), findsOneWidget);
    });

    testWidgets('coming back without having opened Settings checks nothing', (
      tester,
    ) async {
      await refuseThenOpenSettings(tester, openSettings: false);
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: null),
      );
      final before = checks();

      drive(tester, away);
      drive(tester, back);
      await tester.pump();

      expect(checks(), before);
      expect(find.text('No folder chosen'), findsOneWidget);
    });

    testWidgets('a folder picked after Settings was opened wins', (
      tester,
    ) async {
      // Settings opened but never reached — the desktop's is inert — so
      // the user picks another folder instead.
      await refuseThenOpenSettings(tester, leave: false);
      final other = '${tempDir.path}/elsewhere/camera';
      Directory(other).createSync(recursive: true);
      picker.onPick = () => other;
      core.reply<wire.CoreCommandCheckFolder>(
        const wire.ReplyResultFolderChecked(refusal: null),
      );
      await pickFolder(
        tester,
        until: () => controller.state.entries[0].localRoot == other,
        what: 'the other folder to become the local root',
      );
      final before = checks();

      drive(tester, away);
      drive(tester, back);
      await tester.pump();

      expect(checks(), before, reason: 'the refused folder was replaced');
      expect(find.text(other), findsOneWidget);
    });
  });

  testWidgets('field errors render under their own field', (tester) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-options');
    expect(find.text('folder missing'), findsNothing);

    controller.state.recordEntryFieldErrors(
      0,
      localFolder: 'folder missing',
      remoteRoot: 'remote missing',
    );
    await tester.pump();

    expect(find.text('folder missing'), findsOneWidget);
    expect(find.text('remote missing'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('run-setup-address')))
          .decoration
          ?.errorText,
      isNull,
    );
  });

  testWidgets('starting: inputs and button disabled, progress shown', (
    tester,
  ) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-options');

    controller.state.recordOutcome(const RunSetupStarting());
    await tester.pump();

    expect(startEnabled(tester), isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    for (final key in const [
      'run-setup-remote-root',
      'run-setup-address',
      'run-setup-profile-name',
    ]) {
      expect(tester.widget<TextField>(find.byKey(Key(key))).enabled, isFalse);
    }
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('run-setup-dry-run')))
          .onChanged,
      isNull,
    );
  });

  testWidgets('starting: the spinner stands in for the button\'s label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpLoaded(tester);

    controller.state.recordOutcome(const RunSetupStarting());
    await tester.pump();

    expect(
      tester.getSemantics(find.byType(CircularProgressIndicator)),
      isSemantics(label: 'Starting the run'),
    );
    semantics.dispose();
  });

  testWidgets('failed: shows the rendered message and re-enables the button', (
    tester,
  ) async {
    await pumpLoaded(tester);
    expect(find.text('Could not open /x'), findsNothing);

    controller.state.recordOutcome(const RunSetupFailed('Could not open /x'));
    await tester.pump();

    expect(find.text('Could not open /x'), findsOneWidget);
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('failed: the message sits directly above the action bar', (
    tester,
  ) async {
    await pumpLoaded(tester);

    controller.state.recordOutcome(const RunSetupFailed('Could not open /x'));
    await tester.pump();

    final message = tester.getRect(find.text('Could not open /x'));
    final start = tester.getRect(find.byKey(const Key('run-setup-start')));
    final save = tester.getRect(find.byKey(const Key('run-setup-save')));

    // In the action bar, above both exits: the refusal is about the form,
    // not about either way out of it.
    expect(message.bottom, lessThanOrEqualTo(start.top));
    expect(message.bottom, lessThanOrEqualTo(save.top));
  });

  testWidgets('the switch reports to the controller as the user\'s choice', (
    tester,
  ) async {
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-options');

    await tester.tap(find.byKey(const Key('run-setup-dry-run')));
    await tester.pump();

    expect(controller.state.dryRun, isTrue);
  });

  testWidgets('tapping Start with nothing filled in shows the field errors '
      'and does not leave', (tester) async {
    await pumpLoaded(tester);

    await tester.tap(find.byKey(const Key('run-setup-start')));
    await tester.pump();

    expect(controller.state.entries[0].localFolderError, isNotNull);
    expect(
      find.text(controller.state.entries[0].localFolderError!),
      findsOneWidget,
    );
    expect(
      find.text(controller.state.entries[0].remoteRootError!),
      findsOneWidget,
    );
    expect(started, isEmpty);
  });

  testWidgets('a stale started outcome does not leave by itself', (
    tester,
  ) async {
    await pumpLoaded(tester);

    controller.state.recordOutcome(
      const RunSetupStarted(
        RunRequest(
          target: SavedProfileTarget('weekly'),
          deviceName: 'desktop',
          address: null,
          dryRun: true,
        ),
      ),
    );
    await tester.pump();

    expect(started, isEmpty);
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('pick, fill in, Start: leaves through onStart once with the '
      'request', (tester) async {
    final picked = '${tempDir.path}/elsewhere/notes';
    Directory(picked).createSync(recursive: true);
    picker.onPick = () => picked;
    await pumpLoaded(tester);
    await openDisclosure(tester, 'run-setup-options');

    await pickFolder(
      tester,
      until: () => controller.state.entries[0].localRoot == picked,
      what: 'the picked folder to become the local root',
    );
    expect(find.text(picked), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('run-setup-remote-root')),
      '~/notes',
    );
    await tester.enterText(
      find.byKey(const Key('run-setup-address')),
      '10.0.0.9:4242',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('run-setup-start')));
      // The request lands on `started` in the page's `onStart`, which runs
      // off the same outcome the controller records — so the view state
      // going to `RunSetupStarted` is the notification to wait on.
      await settleUntil(
        () => controller.state.outcome is RunSetupStarted,
        what: 'the run to be built',
      );
    });
    await tester.pump();

    final request = started.single;
    final draft = (request.target as DraftTarget).draft;
    expect(draft.entries.single.localRoot, picked);
    expect(request.deviceName, 'desktop');
    expect(draft.peerDeviceId, desktop.deviceId);
    expect(draft.entries.single.remoteRoot, '~/notes');
    expect(request.address, '10.0.0.9:4242');
    expect(request.dryRun, isFalse);
  });

  group('the Diagnostics entry (task 8347dd)', () {
    testWidgets('waits for a folder, since the probe needs one to measure', (
      tester,
    ) async {
      await pumpLoaded(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('run-setup-diagnostics')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('opens over the chosen folder, ready to measure — this is '
        'the only way in before a run', (tester) async {
      final picked = '${tempDir.path}/elsewhere/notes';
      Directory(picked).createSync(recursive: true);
      picker.onPick = () => picked;
      await pumpLoaded(tester);
      await pickFolder(
        tester,
        until: () => controller.state.entries[0].localRoot == picked,
        what: 'the picked folder to become the local root',
      );

      await tester.tap(find.byKey(const Key('run-setup-diagnostics')));
      await tester.pumpAndSettle();

      expect(find.text('Diagnostics'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('scan-cost-run')))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('entries (D10)', () {
    testWidgets('adding an entry gives it its own keyed fields, entry 0 '
        'untouched', (tester) async {
      await pumpLoaded(tester);

      expect(find.byKey(const Key('run-setup-local-folder-1')), findsNothing);

      await tester.tap(find.byKey(const Key('run-setup-add-entry')));
      await tester.pump();

      expect(find.byKey(const Key('run-setup-local-folder')), findsOneWidget);
      expect(find.byKey(const Key('run-setup-local-folder-1')), findsOneWidget);
      expect(find.byKey(const Key('run-setup-remote-root-1')), findsOneWidget);
      expect(find.byKey(const Key('run-setup-pick-folder-1')), findsOneWidget);
    });

    testWidgets('removing an entry drops its fields', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('run-setup-add-entry')));
      await tester.pump();
      expect(find.byKey(const Key('run-setup-local-folder-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('run-setup-remove-entry-1')));
      await tester.pump();

      expect(find.byKey(const Key('run-setup-local-folder-1')), findsNothing);
    });

    testWidgets('the only entry offers no way to remove itself', (
      tester,
    ) async {
      await pumpLoaded(tester);

      expect(find.byKey(const Key('run-setup-remove-entry-0')), findsNothing);
    });

    testWidgets('tapping Start with entry 1 empty shows its own field '
        'errors, not entry 0\'s', (tester) async {
      final picked = '${tempDir.path}/elsewhere/notes';
      Directory(picked).createSync(recursive: true);
      picker.onPick = () => picked;
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('run-setup-add-entry')));
      await tester.pump();
      await pickFolder(
        tester,
        until: () => controller.state.entries[0].localRoot == picked,
        what: 'the picked folder to become entry 0\'s local root',
      );
      await tester.enterText(
        find.byKey(const Key('run-setup-remote-root')),
        '~/notes',
      );

      await tester.tap(find.byKey(const Key('run-setup-start')));
      await tester.pump();

      expect(controller.state.entries[0].localFolderError, isNull);
      expect(controller.state.entries[0].remoteRootError, isNull);
      expect(controller.state.entries[1].localFolderError, isNotNull);
      expect(
        find.text(controller.state.entries[1].localFolderError!),
        findsOneWidget,
      );
      expect(started, isEmpty);
    });

    testWidgets('a File entry offers no scan probe or filter preview', (
      tester,
    ) async {
      await pumpLoaded(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('run-setup-diagnostics')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('File'));
      await tester.pump();

      expect(find.text('No file chosen'), findsOneWidget);
      expect(find.text('Pick a file…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('run-setup-diagnostics')))
            .onPressed,
        isNull,
      );
    });
  });
}
