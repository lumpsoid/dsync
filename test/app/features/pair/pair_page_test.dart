import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/pair/pair_code.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_page.dart';
import 'package:dsync/app/features/pair/pair_scope.dart';
import 'package:dsync/app/features/pair/pair_view_state.dart';
import 'package:dsync/app/features/pair/scan_code_page.dart';
import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/identity/self_signed_certificate.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/app/features/pair/default_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering tests for the Pair page, driven the way the scope contract in
/// `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. Outcomes are written
/// into the view state by the test standing in for the controller's own
/// verdicts, except for the submits that go through the controller: one
/// stops at name validation, the others run the whole path over a temporary
/// state dir and an enrolment fake that accepts.
///
/// The page is two steps, so most tests start by getting a code in: by
/// camera where that is the point, and otherwise through the Paste button
/// over a mocked clipboard.
void main() {
  late Directory tempDir;
  late AppController app;
  late PairController controller;
  late String payloadText;
  var enrolCalls = 0;
  var paired = 0;
  var showOwnCodeTaps = 0;

  setUpAll(() {
    payloadText = PairingPayload(
      certificateDer: certificateDerFromPem(
        generateDeviceIdentity(commonName: 'desktop').certificatePem,
      ),
      address: PeerAddress(host: '192.168.1.5', port: 51234),
      servicePort: 28771,
      token: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]),
    ).encode();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pair_page_test');
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
    controller = PairController(
      app,
      enrol: ({
        required payload,
        required ownIdentity,
        required proposedName,
        required localName,
        required pairedDeviceStore,
      }) async => enrolCalls++,
    );
    appScope.setController(app);
    pairScope.setController(controller);
    // The clipboard, as the way a test gets a code in when how it arrived
    // is not the point of the test. Overridden where it is.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? <String, dynamic>{'text': payloadText}
              : null,
        );
    enrolCalls = 0;
    paired = 0;
    showOwnCodeTaps = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(pairScope.reset);
  tearDown(() => controller.dispose());
  tearDown(() => tempDir.delete(recursive: true));
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  /// The page's camera, as a test hands it over. The default fails loudly,
  /// because the page mounts the camera only when the user asks for it: a
  /// page that built it anyway would be reaching a platform channel no test
  /// host answers, and this says so instead.
  Widget noCameraAskedFor(ValueChanged<String> onScanned) =>
      fail('the page mounted its camera in a test that did not ask for one');

  /// A camera stand-in: one button that fires [raw] through whatever the
  /// scan page handed it. Reading a code and passing the text on is the
  /// whole of what this flow asks of a scanner.
  PairScanner scanning(String raw) =>
      (onScanned) => TextButton(
        onPressed: () => onScanned(raw),
        child: const Text('scan'),
      );

  Future<void> pumpPage(WidgetTester tester, {PairScanner? scanner}) async {
    // Tall enough to hold the whole form: a `ListView` does not build what
    // it cannot show, so a short surface would have a test asserting
    // against a page the user cannot see either.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(
          onPaired: () => paired++,
          onShowOwnCode: () => showOwnCodeTaps++,
          scanner: scanner ?? noCameraAskedFor,
        ),
      ),
    );
  }

  /// A code already read in, when how it arrived is not what the test is
  /// about: through the Paste button, so the page fills itself in exactly
  /// as it does for a user.
  Future<void> withCode(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('pair-paste')));
    await tester.pump();
    await tester.pump();
  }

  /// Taps [target] under real time and waits for the page to leave, which is
  /// the only signal that the submit it started has finished: the work behind
  /// it is real I/O (the identity is generated into the temp dir), and that
  /// never completes under the fake clock a widget test body runs on.
  /// Bounded so a regression fails rather than hangs.
  Future<void> tapAndLeave(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      final deadline = Stopwatch()..start();
      while (paired == 0 && deadline.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
  }

  /// The text a field is showing, by key.
  String fieldText(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

  testWidgets('nothing read yet: two ways in, and nothing to confirm', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('pair-scan')), findsOneWidget);
    expect(find.byKey(const Key('pair-paste')), findsOneWidget);
    expect(find.textContaining('dsync pair show'), findsOneWidget);
    // Nothing to name and nothing to send until a code is there — and no
    // camera mounted merely by opening the page.
    expect(find.byKey(const Key('pair-local-name')), findsNothing);
    expect(find.byKey(const Key('pair-proposed-name')), findsNothing);
    expect(find.byKey(const Key('pair-submit')), findsNothing);
    expect(find.text('scan'), findsNothing);
  });

  testWidgets('the other way round is offered until a code is read', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('pair-show-own-code')));
    await tester.pump();
    expect(showOwnCodeTaps, 1);

    // Gone once there is a code to redeem: showing one instead would throw
    // away the one that has just been read.
    await withCode(tester);
    expect(find.byKey(const Key('pair-show-own-code')), findsNothing);
  });

  testWidgets('a code that was read says which device and where, before '
      'anything is sent', (tester) async {
    await pumpPage(tester);

    await withCode(tester);

    expect(find.byKey(const Key('pair-code-card')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('pair-code-card')),
        matching: find.text('desktop'),
      ),
      findsOneWidget,
    );
    expect(find.text('192.168.1.5:28771'), findsOneWidget);
    expect(find.byKey(const Key('pair-submit')), findsOneWidget);
    expect(enrolCalls, 0);
  });

  testWidgets('this device is offered under the name in its own certificate, '
      'which is what renaming it writes', (tester) async {
    app.state.recordReadyIdentity(
      generateDeviceIdentity(commonName: 'renamed phone'),
      now: DateTime.now(),
    );

    await pumpPage(tester);
    await withCode(tester);

    expect(fieldText(tester, 'pair-proposed-name'), 'renamed phone');
  });

  testWidgets('the two names arrive filled in: this device from the host when '
      'it has no certificate name yet, the desktop from the code it read', (
    tester,
  ) async {
    // No `recordReadyIdentity`: the gate is still loading, so there is no
    // certificate name to offer and the host-name rule stands in.
    await pumpPage(tester);
    await withCode(tester);

    expect(fieldText(tester, 'pair-proposed-name'), defaultThisDeviceName());
    expect(fieldText(tester, 'pair-proposed-name'), isNotEmpty);
    // The common name of the certificate the payload carries.
    expect(fieldText(tester, 'pair-local-name'), 'desktop');
  });

  testWidgets('a name the user typed survives a second code arriving', (
    tester,
  ) async {
    await pumpPage(tester);
    await withCode(tester);

    await tester.enterText(
      find.byKey(const Key('pair-local-name')),
      'the big one',
    );
    // Put that code back and read the same one again: the offer is the
    // page's to make only while the field is still showing the last one.
    await tester.tap(find.byKey(const Key('pair-clear-code')));
    await tester.pump();
    await withCode(tester);

    expect(fieldText(tester, 'pair-local-name'), 'the big one');
  });

  testWidgets('emptying a name shows its line straight away, with no submit', (
    tester,
  ) async {
    await pumpPage(tester);
    await withCode(tester);
    expect(controller.state.proposedNameError, isNull);

    await tester.enterText(find.byKey(const Key('pair-proposed-name')), '  ');
    await tester.pump();

    expect(controller.state.proposedNameError, isNotNull);
    expect(find.text(controller.state.proposedNameError!), findsOneWidget);
    // Typing a name back takes the line away again, also with no submit.
    await tester.enterText(
      find.byKey(const Key('pair-proposed-name')),
      'phone',
    );
    await tester.pump();

    expect(controller.state.proposedNameError, isNull);
    expect(enrolCalls, 0);
  });

  testWidgets('the paste button reads the code out of the clipboard', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': '  $payloadText\n'}
          : null,
    );
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('pair-paste')));
    await tester.pump();
    await tester.pump();

    // Trimmed: a line copied out of a terminal brings its newline along.
    expect(controller.state.code, isA<PairCodeRead>());
    expect(find.text('192.168.1.5:28771'), findsOneWidget);
    // And the pasted code names the desktop, as a scanned one does.
    expect(fieldText(tester, 'pair-local-name'), 'desktop');
    expect(enrolCalls, 0);
  });

  testWidgets('the camera is a page of its own, and what it reads is shown '
      'rather than sent', (tester) async {
    var built = 0;
    await pumpPage(
      tester,
      scanner: (onScanned) {
        built++;
        return scanning(payloadText)(onScanned);
      },
    );
    expect(built, 0);

    await tester.tap(find.byKey(const Key('pair-scan')));
    await tester.pumpAndSettle();

    expect(built, 1);
    expect(find.text('Scan the pairing code'), findsOneWidget);
    // The form is not underneath it: this is a route, not a preview wedged
    // into the page.
    expect(find.byKey(const Key('pair-scan')), findsNothing);

    await tester.tap(find.text('scan'));
    await tester.pumpAndSettle();

    // Back on the Pair page, holding the code and waiting to be told to go.
    expect(find.text('scan'), findsNothing);
    expect(find.byKey(const Key('pair-code-card')), findsOneWidget);
    expect(fieldText(tester, 'pair-local-name'), 'desktop');
    expect(enrolCalls, 0);
    expect(paired, 0);
  });

  testWidgets('a scanned code that is not a payload says so, with both ways '
      'back in', (tester) async {
    await pumpPage(tester, scanner: scanning('https://example.test/'));

    await tester.tap(find.byKey(const Key('pair-scan')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('scan'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not a dsync pairing payload'), findsOneWidget);
    expect(find.byKey(const Key('pair-scan')), findsOneWidget);
    expect(find.byKey(const Key('pair-paste')), findsOneWidget);
    // Nothing to name, and no failed pairing to explain: nothing was tried.
    expect(find.byKey(const Key('pair-submit')), findsNothing);
    expect(controller.state.outcome, isA<PairIdle>());
  });

  testWidgets('a code can be put back for a different one', (tester) async {
    await pumpPage(tester);
    await withCode(tester);

    await tester.tap(find.byKey(const Key('pair-clear-code')));
    await tester.pump();

    expect(find.byKey(const Key('pair-code-card')), findsNothing);
    expect(find.byKey(const Key('pair-scan')), findsOneWidget);
    expect(find.byKey(const Key('pair-submit')), findsNothing);
  });

  testWidgets('submitting: inputs and button disabled, progress shown', (
    tester,
  ) async {
    await pumpPage(tester);
    await withCode(tester);

    controller.state.recordOutcome(const PairSubmitting());
    await tester.pump();

    expect(
      tester.widget<FilledButton>(find.byKey(const Key('pair-submit'))).enabled,
      isFalse,
    );
    // The code cannot be swapped out from under an exchange either.
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('pair-clear-code')))
          .enabled,
      isFalse,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Connecting to the desktop…'), findsOneWidget);
    for (final key in const ['pair-local-name', 'pair-proposed-name']) {
      expect(tester.widget<TextField>(find.byKey(Key(key))).enabled, isFalse);
    }
  });

  testWidgets('submitting: the spinner stands in for the button\'s label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpPage(tester);
    await withCode(tester);

    controller.state.recordOutcome(const PairSubmitting());
    await tester.pump();

    expect(
      tester.getSemantics(find.byType(CircularProgressIndicator)),
      isSemantics(label: 'Pairing'),
    );
    semantics.dispose();
  });

  testWidgets('failed: shows the rendered message and re-enables the button', (
    tester,
  ) async {
    await pumpPage(tester);
    await withCode(tester);
    expect(find.text('Could not reach 10.0.0.9:4242'), findsNothing);

    controller.state.recordOutcome(
      const PairFailed('Could not reach 10.0.0.9:4242'),
    );
    await tester.pump();

    expect(find.text('Could not reach 10.0.0.9:4242'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('pair-submit'))).enabled,
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('field errors render under their own field', (tester) async {
    await pumpPage(tester);
    await withCode(tester);
    expect(find.text('local missing'), findsNothing);

    controller.state.recordNameErrors(
      localName: 'local missing',
      proposedName: null,
    );
    await tester.pump();

    expect(find.text('local missing'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('pair-proposed-name')))
          .decoration
          ?.errorText,
      isNull,
    );
  });

  testWidgets('tapping Pair with an emptied name shows the field error and '
      'does not leave', (tester) async {
    await pumpPage(tester);
    await withCode(tester);

    await tester.enterText(find.byKey(const Key('pair-local-name')), '');
    await tester.tap(find.byKey(const Key('pair-submit')));
    await tester.pump();

    expect(controller.state.localNameError, isNotNull);
    expect(find.text(controller.state.localNameError!), findsOneWidget);
    expect(paired, 0);
    expect(enrolCalls, 0);
  });

  testWidgets('a stale success does not leave by itself', (tester) async {
    await pumpPage(tester);
    await withCode(tester);

    controller.state.recordOutcome(const PairSucceeded('desktop'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(paired, 0);
    // Nor does it confirm anything: the confirmation belongs to the submit
    // that produced it, not to whatever the outcome happens to say.
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a submit that succeeds leaves through onPaired, once', (
    tester,
  ) async {
    await pumpPage(tester);
    await withCode(tester);

    await tester.enterText(find.byKey(const Key('pair-local-name')), 'desktop');
    await tester.enterText(
      find.byKey(const Key('pair-proposed-name')),
      'phone',
    );
    await tapAndLeave(tester, find.byKey(const Key('pair-submit')));

    expect(enrolCalls, 1);
    expect(controller.state.outcome, isA<PairSucceeded>());
    expect(paired, 1);
    // Said in words, and naming the desktop it paired with: the page is
    // leaving, so the row appearing behind it is not the confirmation. The
    // snackbar is the app's, not this `Scaffold`'s, so it is still there
    // once the pop has happened.
    await tester.pump(const Duration(milliseconds: 750));
    expect(find.text('Paired with desktop.'), findsOneWidget);
  });

  testWidgets('a camera that will not start says so, and the clipboard still '
      'pairs', (tester) async {
    await pumpPage(
      tester,
      // What a builder hands back when there is no camera to show — the
      // test's stand-in for `QrScanner`'s own note.
      scanner: (onScanned) => const Text(
        'This build has no camera access, so the QR code cannot be '
        'scanned. Go back and paste the `dsync-pair:v1:` line instead.',
      ),
    );

    await tester.tap(find.byKey(const Key('pair-scan')));
    await tester.pumpAndSettle();
    expect(find.textContaining('no camera'), findsOneWidget);

    // Back out of the camera, and the other way in is untouched: the flow
    // is not blocked on it.
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    await withCode(tester);

    await tester.enterText(find.byKey(const Key('pair-local-name')), 'desktop');
    await tester.enterText(
      find.byKey(const Key('pair-proposed-name')),
      'phone',
    );
    await tapAndLeave(tester, find.byKey(const Key('pair-submit')));

    expect(enrolCalls, 1);
    expect(paired, 1);
  });
}
