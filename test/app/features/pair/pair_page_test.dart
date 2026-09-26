import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/core_link/models/pair_code_reading.dart';
import 'package:dsync/app/features/pair/pair_code.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_page.dart';
import 'package:dsync/app/features/pair/pair_scope.dart';
import 'package:dsync/app/features/pair/pair_view_state.dart';
import 'package:dsync/app/features/pair/scan_code_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';
import '../../support/pump_until.dart';

/// Rendering tests for the Pair page, driven the way the scope contract in
/// `app_scope.dart` intends: the controllers are pinned with
/// `setController` and the page is pumped directly. Outcomes are written
/// into the view state by the test standing in for the controller's own
/// verdicts, except for the submits that go through the controller: one
/// stops at name validation, the others run the whole path over a
/// `FakeHub` that reads every code as the desktop's and accepts.
///
/// The page is two steps, so most tests start by getting a code in: by
/// camera where that is the point, and otherwise through the Paste button
/// over a mocked clipboard.
void main() {
  late FakeHub core;
  late AppController app;
  late PairController controller;
  const payloadText = 'dsync-pair:v2:fake-desktop-code';
  var paired = 0;
  var showOwnCodeTaps = 0;

  /// How many redemptions the page asked the core for.
  int enrolCalls() => core.calls.where((c) => c == 'acceptPairing').length;

  setUp(() {
    core = FakeHub()
      ..pairCodeReading = const ReadPairCode(
        desktopName: 'desktop',
        address: '192.168.1.5:28771',
        deviceId: 'dddd-eeee-ffff-0000',
      );
    app = fakeApp(core);
    controller = PairController(app);
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
    paired = 0;
    showOwnCodeTaps = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(pairScope.reset);
  tearDown(() => controller.dispose());
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

  /// Taps [target] and waits for the page to leave, which is the only
  /// signal that the submit it started has finished.
  Future<void> tapAndLeave(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await pumpUntil(tester, () => paired > 0, what: 'the page to leave');
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
    expect(enrolCalls(), 0);
  });

  testWidgets('the name arrives filled in from the code it read', (
    tester,
  ) async {
    await pumpPage(tester);
    await withCode(tester);

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
    expect(controller.state.localNameError, isNull);

    await tester.enterText(find.byKey(const Key('pair-local-name')), '  ');
    await tester.pump();

    expect(controller.state.localNameError, isNotNull);
    expect(find.text(controller.state.localNameError!), findsOneWidget);
    // Typing a name back takes the line away again, also with no submit.
    await tester.enterText(find.byKey(const Key('pair-local-name')), 'desktop');
    await tester.pump();

    expect(controller.state.localNameError, isNull);
    expect(enrolCalls(), 0);
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
    expect(enrolCalls(), 0);
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
    expect(enrolCalls(), 0);
    expect(paired, 0);
  });

  testWidgets('a scanned code that is not a payload says so, with both ways '
      'back in', (tester) async {
    core.pairCodeReading = const UnreadablePairCode(
      'Not a dsync pairing payload: expected "dsync-pair:"',
    );
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
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('pair-local-name')))
          .enabled,
      isFalse,
    );
  });

  testWidgets("submitting: this device's own id is on screen to compare", (
    tester,
  ) async {
    await pumpPage(tester);
    await withCode(tester);

    // Nothing to compare before anything is sent: the desktop has not been
    // asked its question yet.
    expect(find.byKey(const Key('pair-own-device-id')), findsNothing);

    controller.state.recordOwnDeviceId('a1b2:c3d4:e5f6:0718');
    controller.state.recordOutcome(const PairSubmitting());
    await tester.pump();

    final id = tester.widget<SelectableText>(
      find.byKey(const Key('pair-own-device-id')),
    );
    expect(id.data, 'a1b2:c3d4:e5f6:0718');
    // Monospaced, as the desktop renders the id it is asking about: the
    // groups have to line up by eye.
    expect(id.style?.fontFamily, 'monospace');
    expect(find.textContaining('confirm the id'), findsOneWidget);
  });

  testWidgets('failed: the id stays up, which is when it is read out', (
    tester,
  ) async {
    await pumpPage(tester);
    await withCode(tester);

    controller.state.recordOwnDeviceId('a1b2:c3d4:e5f6:0718');
    controller.state.recordOutcome(const PairFailed('The desktop refused'));
    await tester.pump();

    expect(find.byKey(const Key('pair-own-device-id')), findsOneWidget);
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

  testWidgets('opening the page again starts over: no code, no verdict from '
      'the last visit', (tester) async {
    await pumpPage(tester);
    await withCode(tester);
    controller.state.recordOutcome(
      const PairFailed('Could not reach 10.0.0.9:4242'),
    );
    controller.state.recordLocalNameError('local missing');
    await tester.pump();

    // Left and come back: the controller is the cached scope instance and
    // outlived the page, so the page is what has to say where it starts.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await pumpPage(tester);

    expect(find.text('Could not reach 10.0.0.9:4242'), findsNothing);
    expect(find.text('local missing'), findsNothing);
    expect(find.byKey(const Key('pair-code-card')), findsNothing);
    expect(find.byKey(const Key('pair-scan')), findsOneWidget);
  });

  testWidgets('a field error renders under the field', (tester) async {
    await pumpPage(tester);
    await withCode(tester);
    expect(find.text('local missing'), findsNothing);

    controller.state.recordLocalNameError('local missing');
    await tester.pump();

    expect(find.text('local missing'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('pair-local-name')))
          .decoration
          ?.errorText,
      'local missing',
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
    expect(enrolCalls(), 0);
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
    await tapAndLeave(tester, find.byKey(const Key('pair-submit')));

    expect(enrolCalls(), 1);
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
    await tapAndLeave(tester, find.byKey(const Key('pair-submit')));

    expect(enrolCalls(), 1);
    expect(paired, 1);
  });
}
