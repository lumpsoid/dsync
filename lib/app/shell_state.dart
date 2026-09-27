import 'package:flutter/foundation.dart';

import 'shell_destination.dart';
import 'shell_layout.dart';
import 'shell_page.dart';

/// Where the user is in the app, independent of how the window lays it
/// out: the current [destination], and what each destination has open over
/// its own page.
///
/// **The shell owns this; the pages do not.** Every page reaches the next
/// through a callback, and the entrypoint answers each one with a move on
/// this value (`openDevice`, `select`, ...). The navigator's stack is then
/// worked out from it by [pages], for whichever [ShellLayout] the window
/// has at that moment — so a resize across the breakpoint re-lays the same
/// state out rather than translating one stack into another, and an open
/// device page stays open.
///
/// **Only what is kept per destination is here.** Devices is the one
/// destination that opens anything inside the shell — a device's own page,
/// by id ([openDeviceId]), over the list or beside it. It is a field rather than a
/// list of pages per destination so a device page cannot be stacked over
/// Settings, nor two of them over each other. Step-by-step flows (Pair,
/// Run setup, Run) are not shell state: they are pushed over the whole
/// window and dismissed when done, so no layout change needs to redraw
/// them.
@immutable
final class ShellState {
  const ShellState._({required this.destination, required this.openDeviceId});

  /// The home, with nothing open: where the app starts.
  static const home = ShellState._(
    destination: ShellDestination.profiles,
    openDeviceId: null,
  );

  /// The destination on screen.
  final ShellDestination destination;

  /// The device whose page is open on Devices, or `null` for the list
  /// alone. Kept while another destination is on screen, so coming back to
  /// Devices finds the device the user left — the rail's promise that each
  /// destination keeps its place.
  ///
  /// **The one selection there is.** Opened over the list or shown beside
  /// it, it is the same device, so a resize across either breakpoint keeps
  /// it; the list marks its row from this and nothing else.
  final String? openDeviceId;

  /// [target] on screen, with whatever it had open still open — unless it
  /// is already on screen: choosing the destination the user is in goes
  /// back to its own page, the way a rail's selected entry does.
  ShellState select(ShellDestination target) => ShellState._(
    destination: target,
    openDeviceId: target == destination && target == ShellDestination.devices
        ? null
        : openDeviceId,
  );

  /// Devices on screen with [deviceId]'s own page open — over the list, or
  /// beside it on a window with room for both.
  ShellState openDevice(String deviceId) => ShellState._(
    destination: ShellDestination.devices,
    openDeviceId: deviceId,
  );

  /// Back to the device list: the open device's page is closed, wherever
  /// the user is. Beside the list, that leaves the pane saying none is
  /// open.
  ShellState closeDevice() =>
      ShellState._(destination: destination, openDeviceId: null);

  /// Devices' list on screen, for "New run": every run is born on a device
  /// row, so a device page left open there would stand between the user
  /// and the list they came to pick from.
  ShellState newRun() => const ShellState._(
    destination: ShellDestination.devices,
    openDeviceId: null,
  );

  /// The state once [page] — the top of [pages] — has been popped by a
  /// back gesture, the app-bar arrow or Esc.
  ///
  /// A destination's root only pops on a compact window, where it sits
  /// over its [ShellDestination.compactParent]: popping it lands there. The
  /// home is the bottom of every stack and never pops.
  ///
  /// Devices' two panes are a destination's root too, and never pop: the
  /// device beside the list is not *over* anything, so back has no step to
  /// take there — closing it would only swap it for the empty pane.
  ShellState popped(ShellPage page) => switch (page) {
    ShellDeviceDetail() => closeDevice(),
    ShellDevicesListDetail() => this,
    ShellDestinationRoot(:final destination) =>
      switch (destination.compactParent) {
        null => this,
        final parent => select(parent),
      },
  };

  /// The navigator's stack for [layout], bottom first.
  ///
  /// Compact: the destination over the chain of pages it is pushed from
  /// (Profiles → Devices → This device), each with what it has open, so
  /// back walks the same steps a phone always has. With a rail: the
  /// destination alone, with what it has open — the rail is the way to
  /// every other destination, so none of them sits under it and back never
  /// leaves the destination on screen. With the extended rail, Devices is
  /// one page of two panes ([ShellDevicesListDetail]) whatever is open, and
  /// the open device is drawn beside the list rather than stacked over it.
  List<ShellPage> pages(ShellLayout layout) => switch (layout) {
    ShellLayout.compact => [
      for (final step in _compactChain(destination)) ..._stackOf(step),
    ],
    ShellLayout.rail => _stackOf(destination),
    ShellLayout.extendedRail => [
      if (destination == ShellDestination.devices)
        const ShellDevicesListDetail()
      else
        ShellDestinationRoot(destination),
    ],
  };

  /// [destination]'s own page with what is open over it.
  List<ShellPage> _stackOf(ShellDestination destination) => [
    ShellDestinationRoot(destination),
    if (destination == ShellDestination.devices)
      if (openDeviceId case final deviceId?) ShellDeviceDetail(deviceId),
  ];

  /// The destinations a compact window stacks to show [destination],
  /// bottom first.
  static List<ShellDestination> _compactChain(ShellDestination destination) =>
      switch (destination.compactParent) {
        null => [destination],
        final parent => [..._compactChain(parent), destination],
      };

  @override
  bool operator ==(Object other) =>
      other is ShellState &&
      other.destination == destination &&
      other.openDeviceId == openDeviceId;

  @override
  int get hashCode => Object.hash(destination, openDeviceId);

  @override
  String toString() => 'ShellState(${destination.name}, $openDeviceId)';
}
