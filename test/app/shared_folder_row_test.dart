import 'package:dsync/app/paired_device_row.dart';
import 'package:dsync/app/shared_folder_row.dart';
import 'package:test/test.dart';

/// `SharedFolderRow.renderAll` over plain values: the one place the
/// paired-device list is turned inside out, so the inversion is checked
/// here and no page test has to.
void main() {
  PairedDeviceRow device(String name, List<String> roots) => PairedDeviceRow(
    name: name,
    deviceId: 'id-$name',
    address: '10.0.0.7:28771',
    pairedAt: DateTime.utc(2026, 9, 15),
    agreedRoots: roots,
    certificateIssuedAt: DateTime.utc(2026, 1, 1),
    certificateExpiresAt: DateTime.utc(2027, 1, 1),
    certificateWarning: null,
    verifiedAt: null,
  );

  test('one row per folder, sorted, whichever devices hold it', () {
    final rows = SharedFolderRow.renderAll([
      device('desktop', ['/home/me/sync', '/home/me/notes']),
      device('laptop', ['/home/me/sync']),
    ]);

    expect(rows.map((row) => row.rootPath), [
      '/home/me/notes',
      '/home/me/sync',
    ]);
    expect(rows.last.shareCount, 2);
  });

  test('a row carries every paired device, on or off', () {
    final rows = SharedFolderRow.renderAll([
      device('desktop', ['/home/me/sync']),
      device('laptop', const []),
    ]);

    // The laptop shares nothing and is still a toggle on the folder — that
    // is how a folder is granted from this page.
    expect(rows.single.devices.map((device) => device.name), [
      'desktop',
      'laptop',
    ]);
    expect(rows.single.devices.map((device) => device.isShared), [true, false]);
  });

  test('the summary names the devices rather than counting them', () {
    final one = SharedFolderRow.renderAll([
      device('desktop', ['/home/me/sync']),
    ]).single;
    final two = SharedFolderRow.renderAll([
      device('desktop', ['/home/me/sync']),
      device('laptop', ['/home/me/sync']),
    ]).single;

    expect(one.reachSummary, 'Only desktop may reach this folder.');
    expect(two.reachSummary, 'desktop and laptop may reach this folder.');
  });

  test('a folder held by one device warns that it is about to vanish', () {
    final one = SharedFolderRow.renderAll([
      device('desktop', ['/home/me/sync']),
    ]).single;
    final two = SharedFolderRow.renderAll([
      device('desktop', ['/home/me/sync']),
      device('laptop', ['/home/me/sync']),
    ]).single;

    // A root is stored per device, so the last withdrawal takes the folder
    // with it. Said before the toggle, not after.
    expect(one.note, contains('stops being listed here'));
    expect(two.note, isNull);
  });

  test('the path is carried whole; shortening it is the page width\'s', () {
    const long = '/storage/emulated/0/Android/data/dev.dsync/files/notes';
    final row = SharedFolderRow.renderAll([
      device('desktop', [long]),
    ]).single;

    expect(row.rootPath, long);
  });

  test('no devices means no folders, rather than an empty-named one', () {
    expect(SharedFolderRow.renderAll(const []), isEmpty);
    expect(SharedFolderRow.devicesOf(const [], rootPath: null), isEmpty);
  });

  test('a folder with no path yet starts every device off', () {
    final devices = SharedFolderRow.devicesOf([
      device('desktop', ['/home/me/sync']),
    ], rootPath: null);

    expect(devices.single.isShared, isFalse);
  });
}
