import 'package:flutter/foundation.dart';

import 'shell_destination.dart';

/// One page on the shell's stack, as a plain value: what `ShellState` lays
/// out for a layout, and what the shell's navigator keys its routes by.
///
/// A value rather than a route so the stack can be worked out, compared
/// and tested without a widget, and so the same page keeps its route — and
/// the state under it — when a resize lays the stack out again.
@immutable
sealed class ShellPage {
  const ShellPage();
}

/// A destination's own page, the root of whatever is opened over it.
final class ShellDestinationRoot extends ShellPage {
  const ShellDestinationRoot(this.destination);

  final ShellDestination destination;

  @override
  bool operator ==(Object other) =>
      other is ShellDestinationRoot && other.destination == destination;

  @override
  int get hashCode => destination.hashCode;

  @override
  String toString() => 'ShellDestinationRoot(${destination.name})';
}

/// One paired device's own page, opened over Devices, by id — the handoff
/// carries the id and the page loads the rest. Only where the window has
/// no room for it beside the list ([ShellDevicesListDetail]).
final class ShellDeviceDetail extends ShellPage {
  const ShellDeviceDetail(this.deviceId);

  final String deviceId;

  @override
  bool operator ==(Object other) =>
      other is ShellDeviceDetail && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() => 'ShellDeviceDetail($deviceId)';
}

/// Devices' own page on a window wide enough for two panes: the device list,
/// and beside it the device `ShellState.openDeviceId` names — or a line
/// saying none is open.
///
/// **A page of its own rather than [ShellDestinationRoot] with a flag,** so
/// crossing into or out of this layout replaces the bottom of the stack: the
/// shell lays that out as a resize, with no push or pop animated, rather
/// than as the device page being closed or opened under the user.
///
/// **It carries no device id.** The open device is the shell state's, read
/// there when the page is drawn. An id here would make every change of
/// selection a different page, and so a new route — the list would lose
/// its keyboard focus on every arrow press.
final class ShellDevicesListDetail extends ShellPage {
  const ShellDevicesListDetail();

  @override
  bool operator ==(Object other) => other is ShellDevicesListDetail;

  @override
  int get hashCode => (ShellDevicesListDetail).hashCode;

  @override
  String toString() => 'ShellDevicesListDetail()';
}
