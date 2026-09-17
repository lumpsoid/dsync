/// A named, saved run (the head's home list): a `RunRequest` minus the
/// per-run choices, kept so a run the user repeats unchanged needs no
/// typing the second time. Carries the local root, the peer's device id,
/// the remote root and the job count; deliberately not carried are the
/// address (SPEC §4.4's manual re-entry hatch is per run — the address that
/// worked is written back to the paired-device store anyway) and the
/// dry-run choice (per run, opt-in — see `RunSetupController`).
///
/// **The id is [ReplicaConnector.profileIdFor]'s derivation over the
/// triple.** That is what keys the archive and lock (SPEC §8.1, §8.3), so
/// a profile saved with it re-runs into the archive it always wrote — the
/// profile and its archive line up by construction. A profile whose fields
/// are later edited keeps its id: the connector derives the archive id from
/// the request it is building, never from the saved profile, so the stored
/// id is only the profile's own key in its store.
///
/// Head-owned, and not SPEC §12's file: §12's TOML names a peer by device
/// *name* through `peer://` and is legible to `dsync sync <profile>`, but
/// this profile's local root is a platform grant, not a portable path, so a
/// head profile is not runnable on a desktop and must not pretend to be
/// §12's. It is keyed by device *id* — the durable half of the pairing —
/// for the same reason [RunRequest.peerDeviceId] is.
class SyncProfile {
  const SyncProfile({
    required this.id,
    required this.name,
    required this.localRootPath,
    required this.peerDeviceId,
    required this.remoteRootPath,
    required this.jobs,
  });

  /// The derived profile id — [ReplicaConnector.profileIdFor] over the
  /// triple below, hex, and the key this profile is stored and deleted by.
  final String id;

  /// What the user named it; shown on the home list. Not unique and not a
  /// key — two profiles may share a name.
  final String name;

  /// Side `a`: the absolute path the run syncs (SPEC §4.4, §11.2).
  final String localRootPath;

  /// The peer's grouped device id, what the paired-device store resolves
  /// the peer by and what the archive is keyed under.
  final String peerDeviceId;

  /// Side `b`, unexpanded, exactly as `RunRequest.remoteRootPath` carries
  /// it: the desktop expands `~` in its own environment.
  final String remoteRootPath;

  /// Hashing concurrency for the local scan, as the request that produced
  /// this profile carried it.
  final int jobs;

  /// The same saved run against [path] instead — what the home list saves
  /// when the user re-picks the local folder of a profile whose grant was
  /// withdrawn.
  ///
  /// The id is kept rather than re-derived: as the class doc comment says,
  /// a profile whose fields are edited keeps its id, because the stored id
  /// is only this profile's key in its store and the archive id a run
  /// writes under is derived from the request being built.
  SyncProfile withLocalRoot(String path) => SyncProfile(
    id: id,
    name: name,
    localRootPath: path,
    peerDeviceId: peerDeviceId,
    remoteRootPath: remoteRootPath,
    jobs: jobs,
  );
}
