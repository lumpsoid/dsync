import 'package:dsync/app/app_controller.dart';
import 'package:dsync/app/core_link/core_link.dart';

import 'fake_hub.dart';

import 'package:dsync/app/core_link/models/archive_info.dart';
import 'package:dsync/app/core_link/models/entry_view.dart';
import 'package:dsync/app/core_link/models/paired_device_info.dart';
import 'package:dsync/app/core_link/models/profile_entry.dart';
import 'package:dsync/app/core_link/models/replica_side.dart';
import 'package:dsync/app/core_link/models/root_kind.dart';

/// The clock every head test reads unless it moves it.
DateTime fixedNow() => DateTime.utc(2026, 6, 1, 12);

/// An [AppController] whose [CoreLink] runs over [hub], on the desktop rule
/// (no support dir), reading [now].
AppController fakeApp(FakeHub hub, {DateTime Function()? now}) => AppController(
  CoreLink(hub),
  supportDir: () async => null,
  now: now ?? fixedNow,
);

/// A paired device as the core lists it. Every field has a plain default,
/// so a test names only what it is about.
PairedDeviceInfo pairedDevice({
  String deviceId = 'aaaa-bbbb-cccc-dddd',
  String name = 'desktop',
  String? commonName = 'desktop.local',
  List<String> grantedRoots = const [],
  String address = '192.168.1.20:28771',
  DateTime? pairedAt,
  DateTime? verifiedAt,
  DateTime? issuedAt,
  DateTime? expiresAt,
  String? expiryNote,
}) => PairedDeviceInfo(
  deviceId: deviceId,
  name: name,
  commonName: commonName,
  grantedRoots: grantedRoots,
  address: address,
  pairedAt: pairedAt ?? DateTime.utc(2026, 1, 2),
  verifiedAt: verifiedAt,
  issuedAt: issuedAt ?? DateTime.utc(2026, 1, 1),
  expiresAt: expiresAt ?? DateTime.utc(2036, 1, 1),
  expiryNote: expiryNote,
);

/// A head-shaped saved profile as the core lists it: one folder entry of
/// [localRoot] and [remoteRoot] under [entryId], or [entries] when given.
HeadProfile headProfile({
  String name = 'notes',
  String? entryId,
  String localRoot = '/storage/emulated/0/Notes',
  String? localRootRefusal,
  String peerDeviceId = 'aaaa-bbbb-cccc-dddd',
  String? peerName = 'desktop',
  String remoteRoot = '~/notes',
  List<EntryView>? entries,
  int? jobs,
  List<String> ignorePatterns = const [],
  bool lastRunUnfinished = false,
}) => HeadProfile(
  name: name,
  peerDeviceId: peerDeviceId,
  peerName: peerName,
  jobs: jobs,
  ignorePatterns: ignorePatterns,
  lastRunUnfinished: lastRunUnfinished,
  entries:
      entries ??
      [
        entryView(
          entryId: entryId ?? 'profile-$name',
          localRoot: localRoot,
          localRootRefusal: localRootRefusal,
          remoteRoot: remoteRoot,
        ),
      ],
);

/// One entry of a head-shaped profile as the core lists it.
EntryView entryView({
  required String entryId,
  RootKind kind = RootKind.folder,
  String localRoot = '/storage/emulated/0/Notes',
  String? localRootRefusal,
  String remoteRoot = '~/notes',
}) => EntryView(
  entryId: entryId,
  kind: kind,
  localRoot: localRoot,
  localRootExpanded: localRoot,
  localRootRefusal: localRootRefusal,
  remoteRoot: remoteRoot,
);

/// An archive log as the core lists it.
ArchiveInfo archiveInfo({
  String entryId = 'profile-notes',
  ReplicaSide side = ReplicaSide.a,
  String? logPath,
  String? rootPath = '/storage/emulated/0/Notes',
  int sizeBytes = 2048,
  DateTime? lastModified,
}) => ArchiveInfo(
  logPath: logPath ?? '/fake/state/$entryId-${side.name}.jsonl',
  entryId: entryId,
  side: side,
  rootPath: rootPath,
  sizeBytes: sizeBytes,
  lastModified: lastModified ?? DateTime.utc(2026, 5, 30),
);
