import 'dart:io';
import 'dart:typed_data';

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
import 'package:flutter/material.dart';
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

  Future<void> pumpPage(WidgetTester tester) =>
      tester.pumpWidget(MaterialApp(home: PairPage(onPaired: () => paired++)));

  testWidgets('idle: three fields, the instruction, and an enabled button', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('pair-payload')), findsOneWidget);
    expect(find.byKey(const Key('pair-local-name')), findsOneWidget);
    expect(find.byKey(const Key('pair-proposed-name')), findsOneWidget);
    expect(find.textContaining('dsync pair show'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).enabled,
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
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

    controller.state.recordOutcome(const PairSucceeded());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(paired, 0);
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
    // Real work runs here — the identity is generated into the temp dir —
    // which never completes under the fake clock a widget test body runs
    // on, so the tap that starts it and the wait for it both go under
    // `runAsync`, where time is real. Bounded so a regression fails rather
    // than hangs.
    await tester.runAsync(() async {
      await tester.tap(find.byType(FilledButton));
      final deadline = Stopwatch()..start();
      while (paired == 0 && deadline.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    expect(enrolCalls, 1);
    expect(controller.state.outcome, isA<PairSucceeded>());
    expect(paired, 1);
  });
}
