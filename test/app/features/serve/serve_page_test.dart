import 'dart:io';

import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/features/serve/serve_controller.dart';
import 'package:dsync/app/features/serve/serve_page.dart';
import 'package:dsync/app/features/serve/serve_scope.dart';
import 'package:dsync/app/features/serve/serve_view_state.dart';
import 'package:dsync/app/paired_device_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/clipboard.dart';
import '../../support/fake_hub.dart';
import '../../../support/fake_screen_wake.dart';
import '../../support/fake_head.dart';

/// The Serve page as a rendering test: every [ServeStatus] case, what the
/// page says about the folders this host serves, and the two calls the
/// toggle makes.
///
/// The controller is a stand-in that records [ServeController.start] and
/// [ServeController.stop] instead of binding a socket — the page's job is
/// to call them and to draw what the view state holds, and whether a bind
/// actually works is `serve_controller_test.dart`'s question.
void main() {
  late AppController app;
  late _FakeServeController controller;

  setUp(() async {
    app = fakeApp(FakeHub());
    appScope.setController(app);
    controller = _FakeServeController(app);
    serveScope.setController(controller);
  });

  // Scopes are process-global: reset both so a pin cannot leak into the
  // next test.
  tearDown(appScope.reset);
  tearDown(serveScope.reset);
  tearDown(() => app.dispose());

  PairedDeviceRow row(String name, {List<String> roots = const []}) =>
      PairedDeviceRow(
        name: name,
        deviceId: 'aaaa:bbbb',
        address: '10.0.0.7:28771',
        pairedAt: DateTime.utc(2026, 9, 15),
        agreedRoots: roots,
        certificateIssuedAt: DateTime.utc(2026, 1, 1),
        certificateExpiresAt: DateTime.utc(2027, 1, 1),
        certificateWarning: null,
        verifiedAt: null,
      );

  Future<void> pumpPage(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: ServePage()));

  testWidgets('the page binds on mount and closes on the way out', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ServePage()));
    expect(controller.starts, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(controller.disposals, 1);
  });

  testWidgets('stopped says nothing can reach this device', (tester) async {
    await pumpPage(tester);
    controller.state.recordStatus(const ServeStopped());
    await tester.pump();

    expect(find.text('Not answering'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('serve-toggle')))
          .value,
      isFalse,
    );
  });

  testWidgets('listening shows the address to type on the other device', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordStatus(const ServeListening('10.0.0.5:28771'));
    await tester.pump();

    expect(find.text('Answering at 10.0.0.5:28771'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('serve-toggle')))
          .value,
      isTrue,
    );
  });

  testWidgets('a refused bind is the line the controller wrote', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.state.recordStatus(
      const ServeFailed('This device could not answer on 0.0.0.0:28771.'),
    );
    await tester.pump();

    expect(
      find.text('This device could not answer on 0.0.0.0:28771.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('serve-toggle')))
          .value,
      isFalse,
    );
  });

  testWidgets('the toggle starts and stops', (tester) async {
    await pumpPage(tester);
    controller.state.recordStatus(const ServeListening('10.0.0.5:28771'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('serve-toggle')));
    await tester.pump();
    expect(controller.stops, 1);

    controller.state.recordStatus(const ServeStopped());
    await tester.pump();
    await tester.tap(find.byKey(const Key('serve-toggle')));
    await tester.pump();
    // One from mounting, one from the tap.
    expect(controller.starts, 2);
  });

  testWidgets('what this host serves is on the page, from the device list', (
    tester,
  ) async {
    app.state.recordDevices([
      row('desktop', roots: const ['/home/me/notes']),
    ]);
    await pumpPage(tester);

    expect(
      find.byKey(const Key('serve-folder-/home/me/notes')),
      findsOneWidget,
    );
    expect(find.text('Only desktop may reach this folder.'), findsOneWidget);
    expect(find.byKey(const Key('serve-no-folders')), findsNothing);
    expect(
      find.byKey(const Key('serve-devices-reaching-nothing')),
      findsNothing,
    );
  });

  testWidgets('a paired device granted nothing is called out here, because '
      'its refusal says nothing (SPEC §4.4)', (tester) async {
    app.state.recordDevices([row('phone-b')]);
    await pumpPage(tester);

    expect(find.byKey(const Key('serve-no-folders')), findsOneWidget);
    expect(
      find.byKey(const Key('serve-devices-reaching-nothing')),
      findsOneWidget,
    );
    expect(find.text('phone-b may reach nothing here.'), findsOneWidget);
  });

  testWidgets('session lines render newest first', (tester) async {
    await pumpPage(tester);
    controller.state.show(
      status: const ServeListening('10.0.0.5:28771'),
      sessions: const [
        '10:00:01  Refused: bad handshake',
        '10:00:00  Serving /home/me/notes',
      ],
    );
    await tester.pump();

    expect(find.byKey(const Key('serve-no-sessions')), findsNothing);
    final lines = tester
        .widgetList<Text>(find.textContaining('10:00:0'))
        .map((text) => text.data)
        .toList();
    expect(lines, [
      '10:00:01  Refused: bad handshake',
      '10:00:00  Serving /home/me/notes',
    ]);
  });

  group('copying (task e3b418)', () {
    testWidgets('the answering address copies exactly, and the toggle still '
        'flips', (tester) async {
      final clipboard = recordClipboard(tester);
      await pumpPage(tester);
      controller.state.recordStatus(const ServeListening('10.0.0.5:28771'));
      await tester.pump();

      await tester.tap(find.byKey(const Key('serve-address-copy')));
      await tester.pump();
      expect(clipboard, ['10.0.0.5:28771']);
      expect(find.text('Address copied.'), findsOneWidget);
      // The button is its own target: copying did not stop the listener.
      expect(controller.stops, 0);

      await tester.tap(find.byKey(const Key('serve-toggle')));
      await tester.pump();
      expect(controller.stops, 1);
    });

    testWidgets('a refused bind copies in its own words', (tester) async {
      final clipboard = recordClipboard(tester);
      await pumpPage(tester);
      controller.state.recordStatus(
        const ServeFailed('This device could not answer on 0.0.0.0:28771.'),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('serve-error-copy')));
      await tester.pump();
      expect(clipboard, ['This device could not answer on 0.0.0.0:28771.']);
    });

    testWidgets('the session lines are selectable, the toggle is not', (
      tester,
    ) async {
      await pumpPage(tester);
      controller.state.recordStatus(const ServeListening('10.0.0.5:28771'));
      await tester.pump();

      expect(
        SelectionContainer.maybeOf(
          tester.element(find.byKey(const Key('serve-no-sessions'))),
        ),
        isNotNull,
      );
      expect(
        SelectionContainer.maybeOf(
          tester.element(find.text('Answering at 10.0.0.5:28771')),
        ),
        isNull,
      );
    });
  });
}

/// A [ServeController] that records the page's two inputs instead of
/// binding anything. The page is given the real view state, so every
/// rendering assertion above goes through the same `recordStatus` and
/// `show` the real controller writes with.
class _FakeServeController extends ServeController {
  _FakeServeController(super.app)
    : super(bindAddress: _loopback, screenWake: FakeScreenWake());

  int starts = 0;
  int stops = 0;
  int disposals = 0;

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> stop() async => stops++;

  @override
  void dispose() {
    disposals++;
    state.dispose();
  }
}

Future<InternetAddress> _loopback() async => InternetAddress.loopbackIPv4;
