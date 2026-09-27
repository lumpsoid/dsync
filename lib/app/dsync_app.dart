import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_bootstrap.dart';
import 'app_scope.dart';
import 'features/archives/archives_page.dart';
import 'features/device_detail/device_detail_page.dart';
import 'features/devices/devices_chrome.dart';
import 'features/devices/devices_page.dart';
import 'features/pair/pair_page.dart';
import 'features/pair/scan_code_page.dart';
import 'features/pair_show/pair_show_page.dart';
import 'features/profiles/profiles_chrome.dart';
import 'features/profiles/profiles_page.dart';
import 'features/run/run_page.dart';
import 'features/run_setup/run_setup_page.dart';
import 'features/serve/serve_page.dart';
import 'features/settings/settings_page.dart';
import 'features/shared_folders/shared_folders_page.dart';
import 'features/this_device/this_device_page.dart';
import 'features/run_setup/run_setup_view_state.dart';
import 'readable_width.dart';
import 'run_request.dart';
import 'shell_destination.dart';
import 'shell_layout.dart';
import 'shell_page.dart';
import 'shell_state.dart';

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
/// **So is the layout.** Whether the window gets a navigation rail or the
/// phone's stack of pushed pages is decided once, by `_AppShell`, from the
/// window's width; where the user is ([ShellState]) is a plain value it
/// owns, laid out for whichever layout applies. A page learns only whether
/// it draws its own way to the other destinations.
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
        AppBootstrapReady() => const _AppShell(),
      },
    );
  }
}

/// The app once bootstrap is ready: the destinations, how the window lays
/// them out, and every hop between pages.
///
/// **The layout is decided here, once, from the window's width**
/// ([ShellLayout.forWidth]). Below the breakpoint the destinations stack as
/// pushed pages, exactly as on a phone; from it they sit on a
/// [NavigationRail] beside the page, and a page that would otherwise draw
/// its own way to them is told the shell does ([ProfilesChrome],
/// [DevicesChrome]). No page reads the window to decide its chrome.
///
/// **Where the user is lives in [ShellState], and this class owns it.**
/// Each page callback that stays inside the shell is answered with a move on
/// that value, and the pane's [Navigator] is *declared* from it
/// ([ShellState.pages]) rather than pushed to. So a resize does not
/// translate one route history into another: it lays the same state out
/// again, the pages it keeps keep their routes (they are keyed by
/// [ShellPage]), and an open device page stays open with its state.
///
/// **Two navigators, one job each.** The pane's holds the destinations and
/// what is opened over them, so drilling into a device keeps the rail in
/// view. The app's root navigator holds the step-by-step flows — Pair and
/// Pair show, Run setup and Run — pushed over the whole window, rail and
/// all, on every layout:
///
///  * Pair and Pair show are a task with an end (a device enrols) and a
///    camera or a code to look at; leaving them half-way through the rail
///    would abandon the listener or the scan with nothing on screen saying
///    so, and success pops both at once back to the list that gained a row.
///  * Run setup and Run are a form and the run it starts. The run holds the
///    screen awake and asks before it is left; a rail beside it would be a
///    way to walk off a running sync without that question.
///
/// Neither flow is shell state: it is on top of whichever layout is under
/// it, so a resize redraws the shell beneath and leaves the flow alone.
class _AppShell extends StatefulWidget {
  const _AppShell();

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  /// The pane's navigator, reached for the system back and for Esc. The
  /// pane keeps its place in the tree on both layouts (it is keyed in the
  /// row), so the navigator and its routes survive a resize.
  final _pane = GlobalKey<NavigatorState>();

  late final _escape = _PopPaneAction(_pane);

  ShellState _shell = ShellState.home;

  void _move(ShellState Function(ShellState shell) move) =>
      setState(() => _shell = move(_shell));

  void _select(ShellDestination destination) =>
      _move((shell) => shell.select(destination));

  @override
  Widget build(BuildContext context) {
    final layout = ShellLayout.forWidth(MediaQuery.sizeOf(context).width);
    final pages = _shell.pages(layout);
    final pane = Expanded(
      key: const ValueKey('shell-pane'),
      // Esc is bound here rather than left to the app's own Esc binding:
      // that one resolves to the nearest route's dismiss action, which a
      // page route declines, so it would never reach this far out.
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): _PopPaneIntent(),
        },
        child: Actions(
          actions: {_PopPaneIntent: _escape},
          // The system back reaches the root navigator first; this hands it
          // to the pane's whenever the pane has something to pop, and lets it
          // through (to leave the app) when the pane is at a destination.
          child: NavigatorPopHandler<Object?>(
            onPopWithResult: (_) => _pane.currentState?.maybePop(),
            child: Navigator(
              key: _pane,
              transitionDelegate: const _ShellTransitions(),
              pages: [
                for (final page in pages)
                  MaterialPage<void>(
                    key: ValueKey(page),
                    child: _pageFor(page, layout),
                  ),
              ],
              // A pop the user made (back, the app-bar arrow, Esc): the
              // navigator has already taken the route off, and the state
              // follows so the next build does not declare it again.
              onDidRemovePage: (removed) {
                for (final page in pages) {
                  if (ValueKey(page) == removed.key) {
                    _move((shell) => shell.popped(page));
                  }
                }
              },
            ),
          ),
        ),
      ),
    );
    return switch (layout) {
      ShellLayout.compact => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [pane],
      ),
      ShellLayout.rail || ShellLayout.extendedRail => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ShellRail(
            selected: _shell.destination,
            extended: layout == ShellLayout.extendedRail,
            onSelect: _select,
            onNewRun: () => _move((shell) => shell.newRun()),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          pane,
        ],
      ),
    };
  }

  Widget _pageFor(ShellPage page, ShellLayout layout) => switch (page) {
    ShellDestinationRoot(:final destination) => _destinationPage(
      destination,
      layout,
    ),
    // One paired device's own page: its certificate, the folders this host
    // shares with it, its name here, and the revoke. Carries the device id
    // and nothing else, per the handoff rule; `onGone` closes it once the
    // device stops being paired, which a revoke there produces.
    ShellDeviceDetail(:final deviceId) => DeviceDetailPage(
      deviceId: deviceId,
      onGone: () => _move((shell) => shell.closeDevice()),
    ),
  };

  /// [destination]'s own page. The leaves take no callbacks because
  /// nothing leads anywhere from them, and hold no id because each is about
  /// this host rather than any one peer:
  ///
  ///  * Shared folders is the device list inverted, one row per folder.
  ///  * Sync history lists the archives with what they cost.
  ///  * Serve makes this device the one a run can be started *against*
  ///    (SPEC §4.4). A destination of its own rather than part of Devices:
  ///    the user's hands are on the device that will serve, and they are
  ///    about to walk over to the one that will dial, so it is an activity
  ///    they start rather than a subsection of device management.
  ///  * Settings is what this installation keeps for itself.
  ///  * This device is this installation's own identity.
  Widget _destinationPage(ShellDestination destination, ShellLayout layout) {
    return switch (destination) {
      ShellDestination.profiles => ProfilesPage(
        onOpenProfile: (profileName) =>
            _openRunSetup(RunSetupFromProfile(profileName)),
        onOpenDevices: () => _select(ShellDestination.devices),
        chrome: switch (layout) {
          ShellLayout.compact => ProfilesOwnChrome(
            onOpenArchives: () => _select(ShellDestination.archives),
            onOpenSettings: () => _select(ShellDestination.settings),
            onOpenServe: () => _select(ShellDestination.serve),
          ),
          ShellLayout.rail ||
          ShellLayout.extendedRail => const ProfilesShellChrome(),
        },
      ),
      ShellDestination.devices => DevicesPage(
        onOpenDevice: (deviceId) =>
            _move((shell) => shell.openDevice(deviceId)),
        onOpenRunSetup: (deviceId) =>
            _openRunSetup(RunSetupFromDevice(deviceId)),
        onOpenPair: _openPair,
        chrome: switch (layout) {
          ShellLayout.compact => DevicesOwnChrome(
            onOpenThisDevice: () => _select(ShellDestination.thisDevice),
            onOpenSharedFolders: () => _select(ShellDestination.sharedFolders),
          ),
          ShellLayout.rail ||
          ShellLayout.extendedRail => const DevicesShellChrome(),
        },
      ),
      ShellDestination.sharedFolders => const SharedFoldersPage(),
      ShellDestination.archives => const ArchivesPage(),
      ShellDestination.serve => const ServePage(),
      ShellDestination.settings => const SettingsPage(),
      ShellDestination.thisDevice => const ThisDevicePage(),
    };
  }

  Future<void> _openPair() {
    final navigator = Navigator.of(context);
    return navigator.push(
      MaterialPageRoute<void>(
        // The camera is named here, the way a scope names the real
        // `enrolWithPeer`: the page takes it as a dependency and a widget
        // test hands it a fake (`PairScanner`). None where this platform
        // has no camera, and the page leads with the line instead.
        builder: (_) => PairPage(
          onPaired: navigator.pop,
          onShowOwnCode: () => _openPairShow(navigator),
          scanner: cameraForThisHost(),
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
  Future<void> _openRunSetup(RunSetupSource source) {
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

/// How the pane's routes come and go when [ShellState.pages] changes.
///
/// Opening or closing something over a destination animates as a push or
/// a pop, as it always has. Replacing the bottom of the stack does not:
/// that is a rail click moving to another destination, or a resize laying
/// the same place out for the other layout, and neither is a step forward
/// or back — the new page is simply there.
class _ShellTransitions extends TransitionDelegate<void> {
  const _ShellTransitions();

  @override
  Iterable<RouteTransitionRecord> resolve({
    required List<RouteTransitionRecord> newPageRouteHistory,
    required Map<RouteTransitionRecord?, RouteTransitionRecord>
    locationToExitingPageRoute,
    required Map<RouteTransitionRecord?, List<RouteTransitionRecord>>
    pageRouteToPagelessRoutes,
  }) {
    if (!locationToExitingPageRoute.containsKey(null)) {
      return const DefaultTransitionDelegate<void>().resolve(
        newPageRouteHistory: newPageRouteHistory,
        locationToExitingPageRoute: locationToExitingPageRoute,
        pageRouteToPagelessRoutes: pageRouteToPagelessRoutes,
      );
    }
    final results = <RouteTransitionRecord>[];
    // Every route leaving from above `location`, and anything pageless (a
    // menu) it carried, goes without an exit animation.
    void leave(RouteTransitionRecord? location) {
      final exiting = locationToExitingPageRoute[location];
      if (exiting == null) return;
      if (exiting.isWaitingForExitingDecision) {
        exiting.markForComplete(exiting.route.currentResult);
        for (final pageless
            in pageRouteToPagelessRoutes[exiting] ??
                const <RouteTransitionRecord>[]) {
          if (pageless.isWaitingForExitingDecision) {
            pageless.markForComplete(pageless.route.currentResult);
          }
        }
      }
      results.add(exiting);
      leave(exiting);
    }

    leave(null);
    for (final entering in newPageRouteHistory) {
      if (entering.isWaitingForEnteringDecision) entering.markForAdd();
      results.add(entering);
      leave(entering);
    }
    return results;
  }
}

/// Esc as back inside the shell: pops whatever is open over the current
/// destination, the same step as the app-bar arrow.
///
/// Disabled — so the key goes on to whatever else wants it — when the pane
/// has nothing to pop (a destination's own page, where back must not wander
/// into another destination), and while a text field has focus: Esc there
/// belongs to the field, and a half-typed name should not vanish with the
/// page under it. Dialogs and the step-by-step flows are on the root
/// navigator, outside the pane, and keep their own Esc handling.
/// Esc, pressed inside the shell's pane.
class _PopPaneIntent extends Intent {
  const _PopPaneIntent();
}

class _PopPaneAction extends Action<_PopPaneIntent> {
  _PopPaneAction(this._pane);

  final GlobalKey<NavigatorState> _pane;

  @override
  bool isEnabled(_PopPaneIntent intent) {
    final canPop = _pane.currentState?.canPop() ?? false;
    final editing = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    return canPop && editing == null;
  }

  @override
  void invoke(_PopPaneIntent intent) => _pane.currentState?.maybePop();
}

/// The wide window's way around: "New run" on top, the destinations under
/// it, and the installation's own pages (Settings, This device) at the
/// foot, apart from the places a user goes to do something.
///
/// **"New run" leads the rail.** It is the one thing the app is for, so it
/// sits where Material puts a rail's primary action — above everything, on
/// every destination — rather than in the Profiles header, where it would
/// vanish the moment the user went to Devices to look for it. It lands on
/// Devices' list, where every run is born, exactly as the phone's button
/// does.
class _ShellRail extends StatelessWidget {
  const _ShellRail({
    required this.selected,
    required this.extended,
    required this.onSelect,
    required this.onNewRun,
  });

  /// The rail's own destinations, top to bottom.
  static const _destinations = [
    ShellDestination.profiles,
    ShellDestination.devices,
    ShellDestination.sharedFolders,
    ShellDestination.archives,
    ShellDestination.serve,
  ];

  /// The installation's own pages, at the rail's foot.
  static const _footer = [
    ShellDestination.settings,
    ShellDestination.thisDevice,
  ];

  /// The extended rail's width, which the foot's rows are laid to.
  static const _extendedWidth = 256.0;

  final ShellDestination selected;
  final bool extended;
  final ValueChanged<ShellDestination> onSelect;
  final VoidCallback onNewRun;

  @override
  Widget build(BuildContext context) {
    final index = _destinations.indexOf(selected);
    return NavigationRail(
      extended: extended,
      minExtendedWidth: _extendedWidth,
      labelType: extended
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.all,
      // None of them while the foot's page is on screen: that one is
      // marked where it is.
      selectedIndex: index < 0 ? null : index,
      onDestinationSelected: (index) => onSelect(_destinations[index]),
      leading: extended
          ? FloatingActionButton.extended(
              key: const Key('shell-new-run'),
              heroTag: null,
              elevation: 0,
              onPressed: onNewRun,
              icon: const Icon(Icons.sync),
              label: const Text('New run'),
            )
          : FloatingActionButton(
              key: const Key('shell-new-run'),
              heroTag: null,
              elevation: 0,
              tooltip: 'New run',
              onPressed: onNewRun,
              child: const Icon(Icons.sync),
            ),
      trailingAtBottom: true,
      trailing: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          children: [
            for (final destination in _footer)
              _RailFootItem(
                destination: destination,
                selected: destination == selected,
                extended: extended,
                width: _extendedWidth,
                onPressed: () => onSelect(destination),
              ),
          ],
        ),
      ),
      destinations: [
        for (final destination in _destinations)
          NavigationRailDestination(
            icon: Icon(_look(destination).icon),
            selectedIcon: Icon(_look(destination).selectedIcon),
            label: Text(_look(destination).label),
          ),
      ],
    );
  }
}

/// One of the rail's foot entries, drawn the way the rail draws its own
/// destinations — the name beneath the icon on the narrow rail, beside it on
/// the extended one — and marked the way the rail marks a selected one.
class _RailFootItem extends StatelessWidget {
  const _RailFootItem({
    required this.destination,
    required this.selected,
    required this.extended,
    required this.width,
    required this.onPressed,
  });

  final ShellDestination destination;
  final bool selected;
  final bool extended;
  final double width;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final look = _look(destination);
    final key = Key('shell-open-${destination.name}');
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (!extended) {
      // The rail's own destination, drawn by hand: the indicator pill
      // behind the icon and the label beneath it.
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: key,
              isSelected: selected,
              icon: Icon(look.icon),
              selectedIcon: Icon(look.selectedIcon),
              tooltip: look.label,
              style: IconButton.styleFrom(
                minimumSize: const Size(56, 32),
                backgroundColor: selected ? scheme.secondaryContainer : null,
                foregroundColor: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
              onPressed: onPressed,
            ),
            Text(look.label, style: theme.textTheme.labelMedium),
          ],
        ),
      );
    }
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListTile(
          key: key,
          selected: selected,
          selectedTileColor: scheme.secondaryContainer,
          selectedColor: scheme.onSecondaryContainer,
          shape: const StadiumBorder(),
          leading: Icon(selected ? look.selectedIcon : look.icon),
          title: Text(look.label),
          onTap: onPressed,
        ),
      ),
    );
  }
}

/// How the rail draws [destination]: its icon, the filled icon it takes
/// while selected, and its name.
({IconData icon, IconData selectedIcon, String label}) _look(
  ShellDestination destination,
) => switch (destination) {
  ShellDestination.profiles => (
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Profiles',
  ),
  ShellDestination.devices => (
    icon: Icons.devices_outlined,
    selectedIcon: Icons.devices,
    label: 'Devices',
  ),
  ShellDestination.sharedFolders => (
    icon: Icons.folder_shared_outlined,
    selectedIcon: Icons.folder_shared,
    label: 'Shared folders',
  ),
  ShellDestination.archives => (
    icon: Icons.sd_storage_outlined,
    selectedIcon: Icons.sd_storage,
    label: 'Sync history',
  ),
  ShellDestination.serve => (
    icon: Icons.wifi_tethering,
    selectedIcon: Icons.wifi_tethering,
    label: 'Serve',
  ),
  ShellDestination.settings => (
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    label: 'Settings',
  ),
  ShellDestination.thisDevice => (
    icon: Icons.badge_outlined,
    selectedIcon: Icons.badge,
    label: 'This device',
  ),
};

/// The frame around whatever shows before a page may: the same bar the
/// pages carry, and [child] centred under it.
class _BootstrapShell extends StatelessWidget {
  const _BootstrapShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('dsync')),
      body: Center(
        child: ReadableColumn(width: ReadableWidth.form, child: child),
      ),
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
