import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_paths.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/pair_show/pair_show_controller.dart';
import 'package:dsync/app/features/pair_show/pair_show_page.dart';
import 'package:dsync/app/features/pair_show/pair_show_scope.dart';
import 'package:dsync/app/features/pair_show/pair_show_view_state.dart';
import 'package:dsync/app/features/pair_show/pairing_offer.dart';
import 'package:dsync/app/features/pair_show/qr_symbol.dart';
import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering tests for the Show-this-device's-code page, driven the way the
/// scope contract in `app_scope.dart` intends: the controllers are pinned
/// with `setController` and the page is pumped directly.
///
/// The pinned controller's endpoint never finishes binding, so the window it
/// opens on `initState` stays in [PairShowStarting] and each test writes the
/// status it is about — this file is about what the page shows for a status,
/// not about how one is reached, which is the controller test's.
void main() {
  late Directory tempDir;
  late AppController app;
  late PairShowController controller;
  var paired = 0;
  String? copied;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pair_show_page_test');
    app = AppController(() async => AppPaths(tempDir.path), now: DateTime.now);
    controller = PairShowController(app, bind: _neverBinds);
    appScope.setController(app);
    pairShowScope.setController(controller);
    paired = 0;
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() async {
    appScope.reset();
    pairShowScope.reset();
    app.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await tempDir.delete(recursive: true);
  });

  PairingOffer offer({String line = 'dsync-pair:v2:aGVsbG8='}) =>
      PairingOffer.forPayload(
        line,
        address: '192.168.1.5:51234',
        expiresAt: DateTime(2026, 9, 20, 14, 5),
      );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: PairShowPage(onPaired: () => paired++)),
    );
    await tester.pump();
  }

  testWidgets('waits while the endpoint is being bound', (tester) async {
    await pumpPage(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows the code as a symbol and as a line', (tester) async {
    await pumpPage(tester);

    controller.state.recordStatus(PairShowWaiting(offer()));
    await tester.pump();

    expect(find.byType(QrSymbol), findsOneWidget);
    expect(
      find.text('dsync-pair:v2:aGVsbG8='),
      findsOneWidget,
      reason: 'the line is what a terminal on the other device pastes',
    );
    expect(find.textContaining('192.168.1.5:51234'), findsOneWidget);
    expect(find.textContaining('14:05'), findsOneWidget);
  });

  testWidgets('copies the line to the clipboard', (tester) async {
    await pumpPage(tester);
    controller.state.recordStatus(PairShowWaiting(offer()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('pair-show-copy')));
    await tester.pump();

    expect(copied, 'dsync-pair:v2:aGVsbG8=');
    expect(find.text('Pairing code copied.'), findsOneWidget);
  });

  testWidgets('says so when the payload will not fit in a symbol', (
    tester,
  ) async {
    await pumpPage(tester);

    controller.state.recordStatus(
      PairShowWaiting(offer(line: 'dsync-pair:v2:${'a' * 5000}')),
    );
    await tester.pump();

    expect(find.byType(QrSymbol), findsNothing);
    expect(find.textContaining('too large to show as a QR symbol'), findsOne);
  });

  testWidgets('an expired window offers a fresh one', (tester) async {
    await pumpPage(tester);
    controller.state.recordStatus(const PairShowExpired());
    await tester.pump();

    expect(find.byKey(const Key('pair-show-expired')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pair-show-retry')));
    await tester.pump();

    // Back to a window being opened: a spent token is never retried, only
    // replaced.
    expect(controller.state.status, isA<PairShowStarting>());
  });

  testWidgets('a failure is shown with its own line', (tester) async {
    await pumpPage(tester);

    controller.state.recordStatus(
      const PairShowFailed('This device could not open a pairing endpoint.'),
    );
    await tester.pump();

    expect(find.byKey(const Key('pair-show-failed')), findsOneWidget);
    expect(
      find.text('This device could not open a pairing endpoint.'),
      findsOneWidget,
    );
  });

  testWidgets('a pairing confirms itself and leaves', (tester) async {
    await pumpPage(tester);

    controller.state.recordStatus(const PairShowPaired('peer laptop'));
    await tester.pump();

    expect(paired, 1);
    expect(find.text('Paired with peer laptop.'), findsOneWidget);
  });
}

/// A bind that never answers, so the window the page opens on `initState`
/// stays in [PairShowStarting] and a test's own status is the only one the
/// page ever renders.
Future<EnrolmentListener> _neverBinds({
  required DeviceIdentity ownIdentity,
  required Uint8List token,
  required DateTime tokenExpiresAt,
  required PairedDeviceStore pairedDeviceStore,
  required EnrolmentErrorHandler onError,
}) => Completer<EnrolmentListener>().future;
