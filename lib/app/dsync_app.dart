import 'dart:async';

import 'package:flutter/material.dart';

import 'app_bootstrap.dart';
import 'app_scope.dart';
import 'features/archives/archives_page.dart';
import 'features/device_detail/device_detail_page.dart';
import 'features/devices/devices_page.dart';
import 'features/pair/pair_page.dart';
import 'features/pair/scan_code_page.dart';
import 'features/pair_show/pair_show_page.dart';
import 'features/profiles/profiles_page.dart';
import 'features/run/run_page.dart';
import 'features/run_setup/run_setup_page.dart';
import 'features/serve/serve_page.dart';
import 'features/settings/settings_page.dart';
import 'features/shared_folders/shared_folders_page.dart';
import 'features/this_device/this_device_page.dart';
import 'features/run_setup/run_setup_view_state.dart';
import 'run_request.dart';

/// The Flutter head's root: the bootstrap gate and the routes between the
/// pages (SPEC §4.4, §13).
///
/// **Navigation lives here and nowhere else.** Every page takes where a tap
/// leads as a required constructor callback (`ProfilesPage.onOpenProfile`,
/// `RunSetupPage.onStart`, ...) and holds no `Navigator` of its own — a
/// controller cannot navigate without a `BuildContext`, and a page that
/// pushed its own routes would couple two features' shapes together. This
/// file is the one place that knows Profiles → Devices → Pair pops back on
/// success, Run setup pushes Run, and every hop carries an id or a plain
/// [RunRequest], never loaded data.
///
/// **Nothing routes before the gate is ready.** `AppController.bootstrap()`
/// is started by `main()`, before `runApp`; this widget only renders what
/// `AppState.bootstrap` says. Rendering the home against an un-bootstrapped
/// state would read as "no saved profiles", which is the wrong thing to
/// show someone whose store has simply not been read yet — and a failed
/// bootstrap is a refusal `core` made on purpose (a half-written identity,
/// a device store that cannot be decoded), so its message is shown as the
/// page, not swallowed into an empty list. That page offers the sequence
/// again rather than leaving killing the app as the only way out: the
/// causes are conditions on disk, and a user who has just fixed one should
/// not have to relaunch to be believed.
///
/// **Both schemes come off one seed.** Light and dark are the same palette
/// under two brightnesses, so the app reads as itself either way and a
/// colour change is still one line. Which one shows is the device's call —
/// there is no in-app toggle and nothing to persist.
class DsyncApp extends StatelessWidget {
  const DsyncApp({super.key});

  /// The single colour both schemes are derived from.
  static const _seed = Colors.teal;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dsync',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: _seed)),
      darkTheme: ThemeData(
        colorScheme: .fromSeed(seedColor: _seed, brightness: Brightness.dark),
      ),
      themeMode: ThemeMode.system,
      home: const _BootstrapGate(),
    );
  }
}

/// Switches over the sealed `AppBootstrap` and hands the ready case to the
/// home page. A `ListenableBuilder` over `AppState`, not a `FutureBuilder`
/// over `bootstrap()`: the state is the head's one source of truth for the
/// gate, and a second copy of it in a future's snapshot would be a second
/// thing to keep in step.
class _BootstrapGate extends StatelessWidget {
  const _BootstrapGate();

  @override
  Widget build(BuildContext context) {
    final state = appScope.controller.state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => switch (state.bootstrap) {
        AppBootstrapLoading() => const _BootstrapShell(
          // The gate's spinner is the whole screen, so its label is the
          // only thing a screen reader has to go on here.
          child: CircularProgressIndicator(semanticsLabel: 'Starting dsync'),
        ),
        AppBootstrapFailed(:final message) => _BootstrapShell(
          child: _BootstrapFailure(
            message,
            // The same call `main()` makes. `bootstrap()` records
            // `AppBootstrapLoading` before it touches a file, so the retry
            // being in flight is the loading case of the gate's own sum
            // type — there is no second "retrying" flag here to disagree
            // with it, and a second tap cannot arrive because the button
            // is no longer on screen.
            onRetry: () => unawaited(appScope.controller.bootstrap()),
          ),
        ),
        AppBootstrapReady() => ProfilesPage(
          onOpenProfile: (profileName) =>
              _openRunSetup(context, RunSetupFromProfile(profileName)),
          onOpenDevices: () => _openDevices(context),
          onOpenArchives: () => _openArchives(context),
          onOpenSettings: () => _openSettings(context),
          onOpenServe: () => _openServe(context),
        ),
      },
    );
  }

  Future<void> _openDevices(BuildContext context) {
    final navigator = Navigator.of(context);
    return navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DevicesPage(
          onOpenDevice: (deviceId) => _openDeviceDetail(context, deviceId),
          onOpenRunSetup: (deviceId) =>
              _openRunSetup(context, RunSetupFromDevice(deviceId)),
          onOpenPair: () => _openPair(context),
          onOpenThisDevice: () => _openThisDevice(context),
          onOpenSharedFolders: () => _openSharedFolders(context),
        ),
      ),
    );
  }

  /// One paired device's own page: its certificate, the folders this host
  /// shares with it, its name here, and the revoke. Carries the device id
  /// and nothing else, per the handoff rule; [DeviceDetailPage.onGone] pops
  /// it once the device stops being paired, which a revoke there produces.
  Future<void> _openDeviceDetail(BuildContext context, String deviceId) {
    final navigator = Navigator.of(context);
    return navigator.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DeviceDetailPage(deviceId: deviceId, onGone: navigator.pop),
      ),
    );
  }

  /// This installation's own identity. A leaf: it takes no callbacks
  /// because nothing leads anywhere from it.
  Future<void> _openThisDevice(BuildContext context) {
    return Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ThisDevicePage()));
  }

  /// What this host shares and with whom — the device list inverted, one
  /// row per folder. A leaf: it takes no callbacks because nothing leads
  /// anywhere from it, and it holds no id because the page is about this
  /// host rather than any one peer.
  Future<void> _openSharedFolders(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SharedFoldersPage()));
  }

  /// What this installation keeps for itself — one Network section so far,
  /// holding the address the pairing listener binds. A leaf: it takes no
  /// callbacks because nothing leads anywhere from it.
  Future<void> _openSettings(BuildContext context) {
    return Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }

  /// Answering paired devices (SPEC §4.4) — the page that makes this
  /// device the one a run can be started *against*. A leaf: it takes no
  /// callbacks because nothing leads anywhere from it, and it holds no id
  /// because it is about this host rather than any one peer.
  ///
  /// Pushed from the home page rather than from Devices: the user's hands
  /// are on the device that will serve, and they are about to walk over to
  /// the one that will dial, so it is an activity they start rather than a
  /// subsection of device management.
  Future<void> _openServe(BuildContext context) {
    return Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ServePage()));
  }

  /// The Sync history page. A leaf: it takes no callbacks because nothing
  /// leads anywhere from it.
  Future<void> _openArchives(BuildContext context) {
    return Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ArchivesPage()));
  }

  Future<void> _openPair(BuildContext context) {
    final navigator = Navigator.of(context);
    return navigator.push(
      MaterialPageRoute<void>(
        // The camera is named here, the way a scope names the real
        // `enrolWithPeer`: the page takes it as a dependency and a widget
        // test hands it a fake (`PairScanner`).
        builder: (_) => PairPage(
          onPaired: navigator.pop,
          onShowOwnCode: () => _openPairShow(navigator),
          scanner: QrScanner.new,
        ),
      ),
    );
  }

  /// This device's own code, for the pairing where the other device does
  /// the scanning (SPEC §4.4). Pushed over Pair, and a success there lands
  /// on Devices rather than back on Pair: both routes are done once a
  /// device has enrolled, and the row it produced is on the list under
  /// them.
  Future<void> _openPairShow(NavigatorState navigator) {
    return navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PairShowPage(
          onPaired: () {
            navigator.pop(); // this page
            navigator.pop(); // Pair
          },
        ),
      ),
    );
  }

  /// Run setup over [source] — blank for a device, pre-filled for a saved
  /// profile. Each caller names its own case, so there is no pair of
  /// nullables here to keep in step: the sum type is the argument.
  Future<void> _openRunSetup(BuildContext context, RunSetupSource source) {
    final navigator = Navigator.of(context);
    return navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => RunSetupPage(
          source: source,
          onSaved: navigator.pop,
          onStart: (request) => navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => RunPage(request: request, onDone: navigator.pop),
            ),
          ),
        ),
      ),
    );
  }
}

/// The frame around whatever shows before a page may: the same bar the
/// pages carry, and [child] centred under it.
class _BootstrapShell extends StatelessWidget {
  const _BootstrapShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('dsync')),
      body: Center(child: child),
    );
  }
}

/// A failed bootstrap's own message, selectable because it names a file
/// path the user is expected to act on, and [onRetry] beneath it.
///
/// The retry is offered on every failure rather than only the ones that
/// look transient: this widget is handed a rendered message, not the
/// exception, and re-reading two files is cheap enough that guessing wrong
/// costs a frame. A cause that has not been fixed simply fails again into
/// this same screen — which is the honest answer — and one that has (the
/// half-written identity removed, the device store restored from a backup
/// while the app sat here) no longer needs the app killed to be picked up.
class _BootstrapFailure extends StatelessWidget {
  const _BootstrapFailure(this.message, {required this.onRetry});

  final String message;

  /// Re-runs the bootstrap sequence. Named as intent, like every other
  /// callback a page in this head takes: this widget does not know that
  /// what it triggers is `AppController.bootstrap()`, only that the gate
  /// will move again.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            message,
            key: const Key('bootstrap-failed'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('bootstrap-retry'),
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
