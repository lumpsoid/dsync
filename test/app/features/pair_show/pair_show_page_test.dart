import 'dart:async';
import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/pair_show/pair_show_controller.dart';
import 'package:dsync/app/features/pair_show/pair_show_page.dart';
import 'package:dsync/app/features/pair_show/pair_show_scope.dart';
import 'package:dsync/app/features/pair_show/pair_show_view_state.dart';
import 'package:dsync/app/features/pair_show/pairing_offer.dart';
import 'package:dsync/app/features/pair_show/qr_symbol.dart';
import 'package:dsync/app/rust/bindings/bindings.dart' as wire;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_hub.dart';
import '../../support/fake_head.dart';
import '../../support/focus.dart';

/// Rendering tests for the Show-this-device's-code page, driven the way the
/// scope contract in `app_scope.dart` intends: the controllers are pinned
/// with `setController` and the page is pumped directly.
///
/// The fake core never answers the pinned controller's request for a
/// window, so the window a test opens stays in [PairShowStarting] and each test writes the status it
/// is about — this file is about what the page shows for a status, not about
/// how one is reached, which is the controller test's.
void main() {
  late FakeHub core;
  late AppController app;
  late PairShowController controller;
  var paired = 0;
  String? copied;

  setUp(() async {
    // A window the core never answers for, so a test's own status is the
    // only one the page ever renders.
    core = FakeHub()
      ..hold<wire.CoreCommandShowPairing>(Completer<void>().future);
    app = fakeApp(core);
    controller = PairShowController(app, bindAddress: _loopbackBind);
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
  });

  PairingOffer offer({String line = 'dsync-pair:1.0:aGVsbG8='}) =>
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

  /// The page's first step: name the device about to be paired, then ask for
  /// the code. Every test about a status goes through it, because no window
  /// exists until it has.
  Future<void> openWindow(
    WidgetTester tester, {
    String name = 'my laptop',
  }) async {
    await tester.enterText(find.byKey(const Key('pair-show-name')), name);
    await tester.pump();
    await tester.tap(find.byKey(const Key('pair-show-start')));
    await tester.pump();
  }

  testWidgets('asks what to call the device before there is a code', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('pair-show-name')), findsOneWidget);
    // Nothing is bound until a name has been given: the name is what the
    // device that redeems the code is recorded under, so it cannot be
    // decided after the fact — and an empty one is not a name.
    expect(core.sent<wire.CoreCommandShowPairing>(), isEmpty);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('pair-show-start')))
          .enabled,
      isFalse,
    );
  });

  testWidgets('the name it was given is the name it opens the window under', (
    tester,
  ) async {
    final recording = _RecordingController(app);
    // Disposed by the page, which owns whatever controller it is handed.
    pairShowScope.setController(recording);
    await pumpPage(tester);

    await openWindow(tester, name: '  my laptop  ');

    expect(recording.shownFor, 'my laptop');
  });

  testWidgets('waits while the endpoint is being bound', (tester) async {
    await pumpPage(tester);
    await openWindow(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('waiting for a device to use the code draws nothing', (
    tester,
  ) async {
    await pumpPage(tester);
    await openWindow(tester);

    controller.state.recordStatus(PairShowWaiting(offer()));
    await tester.pump();
    // Whatever the switch itself set moving has finished by now.
    await tester.pump(const Duration(seconds: 1));

    // The operator is walking to the other device for up to the whole
    // window: the code and its deadline stand still until something happens.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('shows the code as a symbol and as a line', (tester) async {
    await pumpPage(tester);
    await openWindow(tester);

    controller.state.recordStatus(PairShowWaiting(offer()));
    await tester.pump();

    expect(find.byType(QrSymbol), findsOneWidget);
    expect(
      find.text('dsync-pair:1.0:aGVsbG8='),
      findsOneWidget,
      reason: 'the line is what a terminal on the other device pastes',
    );
    expect(find.textContaining('192.168.1.5:51234'), findsOneWidget);
    expect(find.textContaining('14:05'), findsOneWidget);
  });

  testWidgets('copies the line to the clipboard', (tester) async {
    await pumpPage(tester);
    await openWindow(tester);
    controller.state.recordStatus(PairShowWaiting(offer()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('pair-show-copy')));
    await tester.pump();

    expect(copied, 'dsync-pair:1.0:aGVsbG8=');
    expect(find.text('Pairing code copied.'), findsOneWidget);
  });

  testWidgets('says so when the payload will not fit in a symbol', (
    tester,
  ) async {
    await pumpPage(tester);
    await openWindow(tester);

    controller.state.recordStatus(
      PairShowWaiting(offer(line: 'dsync-pair:1.0:${'a' * 5000}')),
    );
    await tester.pump();

    expect(find.byType(QrSymbol), findsNothing);
    expect(find.textContaining('too large to show as a QR symbol'), findsOne);
  });

  testWidgets('an expired window offers a fresh one', (tester) async {
    await pumpPage(tester);
    await openWindow(tester);
    controller.state.recordStatus(const PairShowExpired(Duration(minutes: 7)));
    await tester.pump();

    expect(find.byKey(const Key('pair-show-expired')), findsOneWidget);
    // How long codes last is the core's window, carried on the status.
    expect(find.textContaining('good for 7 minutes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pair-show-retry')));
    await tester.pumpAndSettle();

    // Back to the name, still filled in: a spent token is never retried,
    // only replaced, and the name is the one thing worth changing before
    // the next one.
    expect(find.byKey(const Key('pair-show-name')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('pair-show-name')))
          .controller
          ?.text,
      'my laptop',
    );
  });

  testWidgets('a failure is shown with its own line', (tester) async {
    await pumpPage(tester);
    await openWindow(tester);

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

  testWidgets('puts the redeeming device\'s id up to be compared', (
    tester,
  ) async {
    await pumpPage(tester);
    await openWindow(tester);

    controller.state.recordStatus(
      const PairShowConfirming(
        deviceId:
            'a1b2:c3d4:e5f6:0718:293a:4b5c:6d7e:8f90:'
            'a1b2:c3d4:e5f6:0718:293a:4b5c:6d7e:8f90',
        peerName: 'my laptop',
      ),
    );
    await tester.pump();

    // Every group of it, wrapped rather than cut: a comparison that cannot
    // see the whole id is not a comparison (SPEC §4.4).
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('pair-show-device-id')))
          .data,
      'a1b2:c3d4:e5f6:0718:293a:4b5c:6d7e:8f90:'
      'a1b2:c3d4:e5f6:0718:293a:4b5c:6d7e:8f90',
    );
    expect(find.textContaining('my laptop'), findsOneWidget);
    expect(find.byKey(const Key('pair-show-confirm')), findsOneWidget);
    expect(find.byKey(const Key('pair-show-refuse')), findsOneWidget);
  });

  /// Drives the page as far as the comparison and taps [key], returning
  /// what the controller was told. One page per answer: the two buttons are
  /// mutually exclusive, and a second `pumpWidget` of the same page reuses
  /// its `State` rather than starting over.
  Future<bool?> tapAnswer(WidgetTester tester, String key) async {
    final recording = _RecordingController(app);
    pairShowScope.setController(recording);
    await pumpPage(tester);
    await openWindow(tester);
    recording.state.recordStatus(
      const PairShowConfirming(deviceId: 'a1b2:c3d4', peerName: 'my laptop'),
    );
    await tester.pump();

    await tester.tap(find.byKey(Key(key)));
    await tester.pump();
    return recording.answered;
  }

  testWidgets('a matching id answers yes', (tester) async {
    expect(await tapAnswer(tester, 'pair-show-confirm'), isTrue);
  });

  testWidgets('an id that is not the operator\'s device answers no', (
    tester,
  ) async {
    expect(await tapAnswer(tester, 'pair-show-refuse'), isFalse);
  });

  testWidgets('the focus starts on the refusal, so Enter never pairs '
      '(task b30d1b)', (tester) async {
    final recording = _RecordingController(app);
    pairShowScope.setController(recording);
    await pumpPage(tester);
    await openWindow(tester);
    recording.state.recordStatus(
      const PairShowConfirming(deviceId: 'a1b2:c3d4', peerName: 'my laptop'),
    );
    await tester.pump();
    expect(focusIsWithin(const Key('pair-show-refuse')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(recording.answered, isFalse);
  });

  testWidgets('Esc backs out of the page, from its field in two presses '
      '(task b30d1b)', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('home')),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PairShowPage(onPaired: () => paired++),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(focusIsWithin(const Key('pair-show-name')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PairShowPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PairShowPage), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a declined device says so and offers a fresh code', (
    tester,
  ) async {
    await pumpPage(tester);
    await openWindow(tester);

    controller.state.recordStatus(const PairShowDeclined());
    await tester.pump();

    // Not an error: turning away a device that was not the one meant is the
    // feature working.
    expect(find.byKey(const Key('pair-show-declined')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pair-show-retry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pair-show-name')), findsOneWidget);
  });

  testWidgets('a pairing confirms itself and leaves', (tester) async {
    await pumpPage(tester);
    await openWindow(tester);

    controller.state.recordStatus(const PairShowPaired('peer laptop'));
    await tester.pump();

    expect(paired, 1);
    expect(find.text('Paired with peer laptop.'), findsOneWidget);
  });
}

/// A controller that records what the page asked it to open a window for,
/// instead of opening one: the page's one job here is to carry the name the
/// user typed into [PairShowController.show], and a real window would need
/// this device's identity off disk, which a widget test's clock does not
/// wait for.
class _RecordingController extends PairShowController {
  _RecordingController(super.app) : super(bindAddress: _loopbackBind);

  String? shownFor;

  /// What the page last answered the comparison with, or `null` while it
  /// has not answered one — the real controller hands it to a live
  /// enrolment, which there is none of here.
  bool? answered;

  @override
  Future<void> show({required String peerName}) async => shownFor = peerName;

  @override
  void answerConfirmation({required bool confirmed}) => answered = confirmed;
}

/// The bind address every controller in this file is built with: the
/// loopback interface. A callback because the production one is a store
/// read.
Future<InternetAddress> _loopbackBind() async => InternetAddress.loopbackIPv4;
