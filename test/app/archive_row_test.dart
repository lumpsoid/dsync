import 'package:dsync/app/archive_row.dart';
import 'package:dsync/app/format_path.dart';
import 'package:dsync/app/profile_row.dart';
import 'package:dsync/app/core_link/models/archive_info.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:test/test.dart';

/// [ArchiveRow.render] over plain values: the join between a log on disk
/// and the saved run that wrote it is a decision, so it is tested as one —
/// no directory, no controller, no pump.
void main() {
  ArchiveInfo archive({String profileId = 'p1', String? rootPath}) =>
      ArchiveInfo(
        logPath: '/state/dsync/$profileId-a.jsonl',
        profileId: profileId,
        side: ReplicaSide.a,
        rootPath: rootPath,
        sizeBytes: 4404019,
        lastModified: DateTime(2026, 9, 15, 11, 21),
      );

  ProfileRow profile({String? peerName = 'desktop'}) => ProfileRow(
    name: 'weekly notes',
    profileId: 'p1',
    peerDeviceId: 'a1b2:c3d4',
    peerName: peerName,
    localRootPath: '/on-device/notes',
    remoteRootPath: '~/notes',
    localRootLabel: PathLabel.of('/on-device/notes'),
    remoteRootLabel: PathLabel.of('~/notes'),
    breakage: null,
    lastRunUnfinished: false,
  );

  test('names the run and the device it syncs with', () {
    final row = ArchiveRow.render(archive(), profile: profile());

    expect(row.title, 'weekly notes');
    expect(row.peerLine, 'syncs with desktop');
    expect(row.note, isNull);
  });

  test('a run whose device was revoked is named by the id that is left', () {
    // The wording the Profiles page uses for the same state: once the
    // pairing is gone the id is all this host knows the peer by.
    final row = ArchiveRow.render(archive(), profile: profile(peerName: null));

    expect(row.peerLine, 'syncs with unpaired device a1b2:c3d4');
    expect(row.note, isNull);
  });

  test('an archive no saved run claims names no device either', () {
    final row = ArchiveRow.render(archive(profileId: 'p9'), profile: null);

    expect(row.title, 'p9');
    expect(row.peerLine, isNull, reason: 'there is no peer to name');
    expect(row.note, 'No saved run uses this history any more.');
  });

  test('a log with no readable header still names its device', () {
    final row = ArchiveRow.render(archive(), profile: profile());

    expect(row.location, contains('no readable header'));
    expect(row.peerLine, 'syncs with desktop');
  });

  test('a readable root is elided, and the size rendered both ways', () {
    final row = ArchiveRow.render(
      archive(rootPath: '/on-device/notes'),
      profile: profile(),
    );

    expect(row.location, '/on-device/notes');
    expect(row.sizeBytes, 4404019);
    expect(row.lastWritten, '2026-09-15');
  });
}
