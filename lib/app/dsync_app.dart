import 'package:flutter/material.dart';

import 'app_bootstrap.dart';
import 'app_scope.dart';
import 'features/devices/devices_page.dart';
import 'features/pair/pair_page.dart';
import 'features/profiles/profiles_page.dart';
import 'features/run/run_page.dart';
import 'features/run_setup/run_setup_page.dart';
import 'features/run_setup/run_setup_view_state.dart';
import 'run_request.dart';

/// The Flutter head's root: the bootstrap gate and the routes between the
/// five pages (SPEC §4.4, §13).
///
/// This file is still where a Flutter dependency leaking into `dsync_core/`
/// would show up: it is the one root that imports both, so anything
/// head-specific that crept into the core would surface here as a
/// dependency cycle. That was its only job while the head was a skeleton;
/// the rest of it is now the wiring below.
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
/// page, not swallowed into an empty list.
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
          child: CircularProgressIndicator(),
        ),
        AppBootstrapFailed(:final message) => _BootstrapShell(
          child: _BootstrapFailure(message),
        ),
        AppBootstrapReady() => ProfilesPage(
          onOpenProfile: (profileId) =>
              _openRunSetup(context, RunSetupFromProfile(profileId)),
          onOpenDevices: () => _openDevices(context),
        ),
      },
    );
  }

  Future<void> _openDevices(BuildContext context) {
    final navigator = Navigator.of(context);
    return navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DevicesPage(
          onOpenRunSetup: (deviceId) =>
              _openRunSetup(context, RunSetupFromDevice(deviceId)),
          onOpenPair: () => _openPair(context),
        ),
      ),
    );
  }

  Future<void> _openPair(BuildContext context) {
    final navigator = Navigator.of(context);
    return navigator.push(
      MaterialPageRoute<void>(
        // The camera is named here, the way a scope names the real
        // `enrolWithPeer`: the page takes it as a dependency and a widget
        // test hands it a fake (`PairScanner`).
        builder: (_) =>
            PairPage(onPaired: navigator.pop, scanner: QrScanner.new),
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
/// path the user is expected to act on.
class _BootstrapFailure extends StatelessWidget {
  const _BootstrapFailure(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: SelectableText(
        message,
        key: const Key('bootstrap-failed'),
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}
