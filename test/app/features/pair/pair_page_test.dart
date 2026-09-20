import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/pair/pair_controller.dart';
import 'package:dsync/app/features/pair/pair_page.dart';
import 'package:dsync/app/features/pair/pair_scope.dart';
import 'package:dsync/app/features/pair/pair_view_state.dart';
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
/// verdicts, except for the two submits that go through the controller:
/// one stops at name validation, the other runs the whole path over a
/// temporary state dir and an enrolment fake that accepts.
void main() {
  late Directory tempDir;
  late AppController app;
  late PairController controller;
  late String payloadText;
  var enrolCalls = 0;
  var paired = 0;

  setUpAll(() {
    payloadText = PairingPayload(
      certificateDer: certificateDerFromPem(
        generateDeviceIdentity(commonName: 'desktop').certificatePem,
      ),
      address: PeerAddress(host: '192.168.1.5', port: 28771),
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
    enrolCalls = 0;
    paired = 0;
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(pairScope.reset);
  tearDown(() => controller.dispose());
  tearDown(() => tempDir.delete(recursive: true));

  /// The page's camera, as a test hands it over. The default fails loudly,
  /// because the page mounts the camera only when the user asks for it: a
  /// page that built it anyway would be reaching a platform channel no test
  /// host answers, and this says so instead.
  Widget noCameraAskedFor(ValueChanged<String> onScanned) =>
      fail('the page mounted its camera in a test that did not ask for one');

  /// A camera stand-in: one button that fires [raw] through whatever the
  /// page handed it. Reading a code and passing the text on is the whole of
  /// what this page asks of a scanner.
  PairScanner scanning(String raw) =>
      (onScanned) => TextButton(
        onPressed: () => onScanned(raw),
        child: const Text('scan'),
      );

  Future<void> pumpPage(WidgetTester tester, {PairScanner? scanner}) async {
    // Tall enough to hold the whole form. On the default 800x600 surface the
    // camera note and the scan button push the last two fields out of the
    // viewport, and a `ListView` does not build what it cannot show — so a
    // test would be asserting against a page the user cannot see either, or
    // scrolling its way around a layout question it is not about.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(
          onPaired: () => paired++,
          scanner: scanner ?? noCameraAskedFor,
        ),
      ),
    );
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

  testWidgets('idle: three fields, the instruction, and an enabled button', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('pair-payload')), findsOneWidget);
    expect(find.byKey(const Key('pair-local-name')), findsOneWidget);
    expect(find.byKey(const Key('pair-proposed-name')), findsOneWidget);
    expect(find.textContaining('dsync pair show'), findsOneWidget);
    // The camera is offered, not mounted: the button is what asks for it.
    expect(find.byKey(const Key('pair-show-camera')), findsOneWidget);
    expect(find.text('scan'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).enabled,
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  /// The text a field is showing, by key.
  String fieldText(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

  testWidgets('the two names arrive filled in: this device from the host, '
      'the desktop from the payload it sent', (tester) async {
    await pumpPage(tester);

    expect(fieldText(tester, 'pair-proposed-name'), defaultThisDeviceName());
    expect(fieldText(tester, 'pair-proposed-name'), isNotEmpty);
    // Nothing to read a desktop name out of until a payload is there.
    expect(fieldText(tester, 'pair-local-name'), isEmpty);

    await tester.enterText(find.byKey(const Key('pair-payload')), payloadText);
    await tester.pump();

    // The common name of the certificate the payload carries.
    expect(fieldText(tester, 'pair-local-name'), 'desktop');
  });

  testWidgets('a name the user typed survives a payload arriving after it', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const Key('pair-local-name')),
      'the big one',
    );
    await tester.enterText(find.byKey(const Key('pair-payload')), payloadText);
    await tester.pump();

    expect(fieldText(tester, 'pair-local-name'), 'the big one');
  });

  testWidgets('emptying a name shows its line straight away, with no submit', (
    tester,
  ) async {
    await pumpPage(tester);
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

  testWidgets('the paste button fills the payload field from the clipboard', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': '  $payloadText\n'}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('pair-payload-paste')));
    await tester.pump();
    await tester.pump();

    // Trimmed: a line copied out of a terminal brings its newline along.
    expect(fieldText(tester, 'pair-payload'), payloadText);
    // And the pasted payload names the desktop, as a scanned one does.
    expect(fieldText(tester, 'pair-local-name'), 'desktop');
  });

  testWidgets('submitting: inputs and button disabled, progress shown', (
    tester,
  ) async {
    await pumpPage(tester);

    controller.state.recordOutcome(const PairSubmitting());
    await tester.pump();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).enabled,
      isFalse,
    );
    // Asking for the camera waits for the exchange too: two submissions
    // racing over one payload is what the controller's guard exists for.
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('pair-show-camera')))
          .enabled,
      isFalse,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Connecting to the desktop…'), findsOneWidget);
    for (final key in const [
      'pair-payload',
      'pair-local-name',
      'pair-proposed-name',
    ]) {
      expect(tester.widget<TextField>(find.byKey(Key(key))).enabled, isFalse);
    }
  });

  testWidgets('submitting: the spinner stands in for the button\'s label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpPage(tester);

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
    expect(find.text('Could not reach 10.0.0.9:4242'), findsNothing);

    controller.state.recordOutcome(
      const PairFailed('Could not reach 10.0.0.9:4242'),
    );
    await tester.pump();

    expect(find.text('Could not reach 10.0.0.9:4242'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).enabled,
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('field errors render under their own field', (tester) async {
    await pumpPage(tester);
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

  testWidgets('tapping Pair with empty names shows the field errors and does '
      'not leave', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const Key('pair-payload')),
      'dsync-pair:v1:AAAA',
    );
    await tester.tap(find.text('Pair'));
    await tester.pump();

    expect(controller.state.localNameError, isNotNull);
    expect(find.text(controller.state.localNameError!), findsOneWidget);
    expect(paired, 0);
    expect(enrolCalls, 0);
  });

  testWidgets('a stale success does not leave by itself', (tester) async {
    await pumpPage(tester);

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

    await tester.enterText(find.byKey(const Key('pair-payload')), payloadText);
    await tester.enterText(find.byKey(const Key('pair-local-name')), 'desktop');
    await tester.enterText(
      find.byKey(const Key('pair-proposed-name')),
      'phone',
    );
    // The pasted payload wraps to many lines and scrolls the button off.
    await tester.scrollUntilVisible(
      find.byType(FilledButton),
      200,
      // The text fields have scrollables of their own; the list's is first.
      scrollable: find.byType(Scrollable).first,
    );
    await tapAndLeave(tester, find.byType(FilledButton));

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

  testWidgets('asking for the camera mounts it, and putting it away unmounts '
      'it', (tester) async {
    var built = 0;
    await pumpPage(
      tester,
      scanner: (onScanned) {
        built++;
        return scanning('scanned')(onScanned);
      },
    );
    expect(built, 0);

    await tester.tap(find.byKey(const Key('pair-show-camera')));
    await tester.pump();

    expect(built, 1);
    expect(find.text('scan'), findsOneWidget);
    expect(find.byKey(const Key('pair-hide-camera')), findsOneWidget);

    await tester.tap(find.byKey(const Key('pair-hide-camera')));
    await tester.pump();

    expect(find.text('scan'), findsNothing);
    expect(find.byKey(const Key('pair-show-camera')), findsOneWidget);
  });

  testWidgets('a scan reaches the controller and leaves through onPaired, '
      'once', (tester) async {
    await pumpPage(tester, scanner: scanning(payloadText));

    await tester.enterText(find.byKey(const Key('pair-local-name')), 'desktop');
    await tester.enterText(
      find.byKey(const Key('pair-proposed-name')),
      'phone',
    );
    await tester.tap(find.byKey(const Key('pair-show-camera')));
    await tester.pump();
    await tapAndLeave(tester, find.text('scan'));

    expect(enrolCalls, 1);
    expect(controller.state.outcome, isA<PairSucceeded>());
    expect(paired, 1);
    // The text that was read is in the field, so a refused scan can be seen
    // next to the reason it was refused.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('pair-payload')))
          .controller
          ?.text,
      payloadText,
    );
  });

  testWidgets('a scan with a name emptied is a field error, and starts no '
      'exchange', (tester) async {
    await pumpPage(tester, scanner: scanning(payloadText));
    // The name for this device arrives filled in, so the only way to reach
    // the validation path is to take it away again.
    await tester.enterText(find.byKey(const Key('pair-proposed-name')), '');
    await tester.tap(find.byKey(const Key('pair-show-camera')));
    await tester.pump();

    await tester.tap(find.text('scan'));
    await tester.pump();

    expect(controller.state.proposedNameError, isNotNull);
    expect(find.text(controller.state.proposedNameError!), findsOneWidget);
    expect(enrolCalls, 0);
    expect(paired, 0);
  });

  testWidgets('a camera that will not start says so, and the paste field still '
      'pairs', (tester) async {
    await pumpPage(
      tester,
      // What a builder hands back when there is no camera to show — the
      // page's fake of `QrScanner`'s own note.
      scanner: (onScanned) => const Text(
        'This build has no camera access, so the QR code cannot be '
        'scanned. Paste the `dsync-pair:v1:` line instead.',
      ),
    );
    await tester.tap(find.byKey(const Key('pair-show-camera')));
    await tester.pump();

    // The camera area says why, and nothing else on the page changed: the
    // page is not blocked on it.
    expect(find.textContaining('no camera'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('pair-payload'))).enabled,
      isTrue,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).enabled,
      isTrue,
    );

    await tester.enterText(find.byKey(const Key('pair-payload')), payloadText);
    await tester.enterText(find.byKey(const Key('pair-local-name')), 'desktop');
    await tester.enterText(
      find.byKey(const Key('pair-proposed-name')),
      'phone',
    );
    await tester.scrollUntilVisible(
      find.byType(FilledButton),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapAndLeave(tester, find.byType(FilledButton));

    expect(enrolCalls, 1);
    expect(paired, 1);
  });
}
