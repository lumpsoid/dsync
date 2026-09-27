import 'package:dsync/app/shell_destination.dart';
import 'package:dsync/app/shell_layout.dart';
import 'package:dsync/app/shell_page.dart';
import 'package:dsync/app/shell_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app shell's state as plain values: where the user is, and the page
/// stack each layout lays that out as. No widget is involved — the shell in
/// `dsync_app.dart` only declares its navigator from [ShellState.pages] and
/// answers pops with [ShellState.popped].
void main() {
  const profiles = ShellDestinationRoot(ShellDestination.profiles);
  const devices = ShellDestinationRoot(ShellDestination.devices);
  const thisDevice = ShellDestinationRoot(ShellDestination.thisDevice);
  const settings = ShellDestinationRoot(ShellDestination.settings);
  const phone = ShellDeviceDetail('a1b2:c3d4');
  const listDetail = ShellDevicesListDetail();

  group('ShellLayout.forWidth', () {
    test('a phone-sized window is compact, up to the rail breakpoint', () {
      expect(ShellLayout.forWidth(360), ShellLayout.compact);
      expect(ShellLayout.forWidth(839.9), ShellLayout.compact);
    });

    test('a wide window gets a rail, extended once there is room', () {
      expect(ShellLayout.forWidth(840), ShellLayout.rail);
      expect(ShellLayout.forWidth(1199.9), ShellLayout.rail);
      expect(ShellLayout.forWidth(1200), ShellLayout.extendedRail);
    });
  });

  group('pages', () {
    test('the app starts on the home, alone, on every layout', () {
      for (final layout in ShellLayout.values) {
        expect(ShellState.home.pages(layout), [profiles], reason: '$layout');
      }
    });

    test('compact stacks a destination over the page it is pushed from', () {
      final state = ShellState.home.select(ShellDestination.thisDevice);

      expect(state.pages(ShellLayout.compact), [profiles, devices, thisDevice]);
      expect(state.pages(ShellLayout.rail), [thisDevice]);
    });

    test('an open device is over Devices on a compact window and beside '
        'a narrow rail', () {
      final state = ShellState.home.openDevice(phone.deviceId);

      expect(state.destination, ShellDestination.devices);
      expect(state.pages(ShellLayout.compact), [profiles, devices, phone]);
      expect(state.pages(ShellLayout.rail), [devices, phone]);
    });

    test('with the extended rail, Devices is one page of two panes, with '
        'a device open or not', () {
      final list = ShellState.home.select(ShellDestination.devices);
      final open = list.openDevice(phone.deviceId);

      expect(list.pages(ShellLayout.extendedRail), [listDetail]);
      expect(open.pages(ShellLayout.extendedRail), [listDetail]);
      // The pane beside the list shows the one selection there is.
      expect(list.openDeviceId, isNull);
      expect(open.openDeviceId, phone.deviceId);
    });

    test('with the extended rail, every other destination is its own page '
        'alone', () {
      final state = ShellState.home
          .openDevice(phone.deviceId)
          .select(ShellDestination.thisDevice);

      expect(state.pages(ShellLayout.extendedRail), [thisDevice]);
      expect(ShellState.home.pages(ShellLayout.extendedRail), [profiles]);
    });

    test('the open device survives every layout it is laid out for', () {
      final state = ShellState.home.openDevice(phone.deviceId);

      // One state, three windows: beside the list, over it, and stacked
      // over the home — the device is the same one on each.
      expect(state.pages(ShellLayout.extendedRail), [listDetail]);
      expect(state.pages(ShellLayout.rail), [devices, phone]);
      expect(state.pages(ShellLayout.compact), [profiles, devices, phone]);
      expect(state.openDeviceId, phone.deviceId);
    });

    test('an open device is kept, not shown, while elsewhere', () {
      final state = ShellState.home
          .openDevice(phone.deviceId)
          .select(ShellDestination.settings);

      expect(state.pages(ShellLayout.rail), [settings]);
      expect(state.pages(ShellLayout.compact), [profiles, settings]);
      // Back on Devices, the device the user left is still open.
      expect(state.select(ShellDestination.devices).pages(ShellLayout.rail), [
        devices,
        phone,
      ]);
    });

    test('compact keeps the open device under what was pushed over it', () {
      final state = ShellState.home
          .openDevice(phone.deviceId)
          .select(ShellDestination.thisDevice);

      expect(state.pages(ShellLayout.compact), [
        profiles,
        devices,
        phone,
        thisDevice,
      ]);
    });
  });

  group('moves', () {
    test('choosing Devices again from Devices goes back to the list', () {
      final state = ShellState.home
          .openDevice(phone.deviceId)
          .select(ShellDestination.devices);

      expect(state.openDeviceId, isNull);
      expect(state.pages(ShellLayout.rail), [devices]);
    });

    test('New run lands on the device list, closing an open device', () {
      final state = ShellState.home
          .openDevice(phone.deviceId)
          .select(ShellDestination.archives)
          .newRun();

      expect(state.destination, ShellDestination.devices);
      expect(state.pages(ShellLayout.rail), [devices]);
    });

    test('choosing another device beside the list replaces the selection',
        () {
      final state = ShellState.home
          .openDevice(phone.deviceId)
          .openDevice('e5f6:0000');

      expect(state.openDeviceId, 'e5f6:0000');
      expect(state.pages(ShellLayout.extendedRail), [listDetail]);
    });

    test('closing a device keeps the destination on screen', () {
      final state = ShellState.home.openDevice(phone.deviceId).closeDevice();

      expect(state.destination, ShellDestination.devices);
      expect(state.openDeviceId, isNull);
    });
  });

  group('popped', () {
    test('popping a device page goes back to the list', () {
      final state = ShellState.home.openDevice(phone.deviceId);

      expect(
        state.popped(phone),
        ShellState.home.select(ShellDestination.devices),
      );
    });

    test('popping a destination lands on the one it was pushed from', () {
      final overDevices = ShellState.home.select(ShellDestination.thisDevice);
      final overHome = ShellState.home.select(ShellDestination.settings);

      expect(
        overDevices.popped(thisDevice).destination,
        ShellDestination.devices,
      );
      expect(overHome.popped(settings), ShellState.home);
    });

    test('the home never pops', () {
      expect(ShellState.home.popped(profiles), ShellState.home);
    });

    test('the two panes never pop, and keep the device beside the list', () {
      final state = ShellState.home.openDevice(phone.deviceId);

      expect(state.popped(listDetail), state);
    });

    test('back through a compact stack walks the steps that built it', () {
      var state = ShellState.home
          .select(ShellDestination.devices)
          .openDevice(phone.deviceId);
      final seen = <List<ShellPage>>[];
      while (state.pages(ShellLayout.compact).length > 1) {
        state = state.popped(state.pages(ShellLayout.compact).last);
        seen.add(state.pages(ShellLayout.compact));
      }

      expect(seen, [
        [profiles, devices],
        [profiles],
      ]);
    });
  });
}
