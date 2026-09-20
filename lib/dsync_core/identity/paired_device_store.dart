import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:dsync/dsync_core/temp_file.dart';

/// The durable set of devices this installation has paired with (SPEC §4.4):
/// each device's certificate pin, this host's name for it, its agreed replica
/// roots, and its last-known address. Persisted in the state directory (SPEC
/// §8.3), beside the device identity and the archives.
///
/// **A concrete class over a real file path, not an interface.** The task
/// that named this class reached for `ArchiveStore`'s reason — "the real
/// implementation is disk-backed and no test can run it" — but that reason
/// does not hold here and did not, on inspection, hold for `ArchiveStore`
/// either: SPEC §8.2 gives its actual reason as "so a SQLite implementation
/// can replace it if the log approach proves inadequate on large trees",
/// which is CLAUDE.md's *second* trigger for an interface (two
/// implementations ship), not its first (the real one can't be tested). A
/// disk-backed store *is* testable — SPEC §14 tests core logic against real
/// temporary directories, and `DeviceIdentityStore` (the closest sibling to
/// this class) is exactly that, with no interface, testing its `Directory`
/// straight against `Directory.systemTemp.createTemp`. No second
/// implementation of this store is planned. Neither trigger applies, so this
/// mirrors `DeviceIdentityStore`: a concrete class over a real path.
///
/// **Freshness: every method reads the file, nothing is cached.** [load],
/// [byDeviceId], [byName], [add], [revoke], [recordConnection] and [grant]
/// each open and parse [_file] fresh — there is no in-memory copy held
/// across calls.
/// This is deliberate, not an oversight: SPEC §4.4 requires that
/// "revocation... take effect for connections attempted after it", and a
/// store that cached its devices in memory across a process's lifetime would
/// have a listener keep trusting a device `unpair` had just removed, in
/// another process, until the listener restarted. Re-reading a file holding a
/// handful of entries on every call is cheap enough that there is no reason
/// to risk that. **What this means for a caller:** do not hold onto a
/// [PairedDevice] (or a [load] result) and use it later to decide whether to
/// trust a connection — call [byDeviceId] (or [byName]) at the moment of the
/// decision, every time, the way `d0e960`'s connection handler and a
/// `peer://` location resolution both have to.
///
/// **Format: one JSON document, rewritten atomically.** The alternative — an
/// append log with tombstones, `JsonlArchiveStore`'s shape (SPEC §8.2) — earns
/// its cost there because a run commits per path (SPEC §7.3) without wanting
/// to rewrite a potentially large file on every one of those commits. Nothing
/// here is like that: a paired-device set is a handful of entries, mutated
/// only by a deliberate human action (pairing, unpairing, granting a root) or
/// by one connection succeeding, never in a tight loop. Rewriting the whole
/// document on every mutation costs nothing worth avoiding, and it avoids the
/// append log's own cost entirely — replaying tombstones, and compacting them
/// away later — for no benefit here. Written with [tempPathFor] and
/// `File.rename`, the same atomic-write pattern `LocalAgent.writeFile` uses
/// for a replica file: never a partially-written document on disk, and never
/// two writers racing each other onto the same final name.
///
/// **Absent vs. damaged.** A missing file is the ordinary first-run case —
/// [load] returns `[]` for it without ever attempting to parse anything. A
/// file that exists but does not decode as this store's shape — truncated,
/// malformed JSON, or well-formed JSON that is not this document — is
/// different in kind, not degree: it throws [PairedDeviceStoreCorruptException]
/// rather than being read as an empty set. An empty set and "this file is
/// damaged" must never look the same on load, because the empty set *is* the
/// answer "trust nobody" — indistinguishable from a real revocation right up
/// until someone re-pairs. Reading damaged bytes as "no devices" would turn a
/// flipped bit into a silent revocation nobody asked for.
class PairedDeviceStore {
  /// Bumped when the on-disk document shape changes. A document claiming a
  /// different version is corruption, not a format this store degrades
  /// gracefully from — there is exactly one shape this store has ever
  /// written.
  static const schemaVersion = 1;

  final File _file;

  /// Distinguishes this write's scratch file from another write's, per
  /// [tempPathFor]'s own contract, within one running process.
  int _nextTempSequence = 0;

  PairedDeviceStore(this._file);

  /// Resolves the standard paired-device store location under the state
  /// directory (SPEC §8.3, §4.4). See [resolveStateDir]. [platform] is
  /// required, not defaulted: every caller states which of SPEC §8.3's rules
  /// it means rather than silently getting Linux's — see
  /// `lib/cli/host_platform.dart` for where the CLI head's real answer
  /// comes from.
  factory PairedDeviceStore.forStateDir({
    Map<String, String> environment = const {},
    required StateDirPlatform platform,
  }) => PairedDeviceStore(
    File('${resolveStateDir(environment, platform)}/paired-devices.json'),
  );

  /// Every currently paired device, freshly read from disk. `[]` when
  /// [_file] does not exist yet — the ordinary first-run case, not
  /// corruption. See the class doc comment for what "freshly" guarantees and
  /// what a caller must do to not miss a revocation.
  Future<List<PairedDevice>> load() async {
    if (!await _file.exists()) return [];

    final String raw;
    try {
      raw = await _file.readAsString();
    } on FileSystemException catch (e) {
      throw PairedDeviceStoreCorruptException(_file.path, e.toString());
    }

    try {
      return _parseDocument(raw);
    } on PairedDeviceStoreCorruptException {
      rethrow;
    } catch (e) {
      // Anything else a malformed document can throw while being decoded or
      // shape-checked below — a JSON syntax error from a truncated write, a
      // failed cast from a field of the wrong type, a missing key. All of it
      // is the same fact from a caller's point of view: this file cannot be
      // trusted, and must not be read as "no devices" (see the class doc
      // comment).
      throw PairedDeviceStoreCorruptException(_file.path, e.toString());
    }
  }

  /// The device pinned to [deviceId], or `null` if none is paired. What
  /// `d0e960` calls with the id it derived from a peer's certificate.
  Future<PairedDevice?> byDeviceId(String deviceId) async {
    for (final device in await load()) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  /// The device named [name] on this host, or `null` if no such pairing
  /// exists. What a `peer://` location resolves through (SPEC §4.4).
  Future<PairedDevice?> byName(String name) async {
    for (final device in await load()) {
      if (device.name == name) return device;
    }
    return null;
  }

  /// Adds [device] as a newly paired device.
  ///
  /// Rejected, not silently disambiguated, when [device]'s name or device id
  /// collides with an already-paired device (SPEC §4.4: "a pairing that would
  /// collide with an existing name is rejected at pairing time... the
  /// operator picks a different name and pairs again"; "the store enforces
  /// it, the same way it already has to enforce that one device id maps to
  /// one entry"). Re-pointing an existing name at a new certificate — the
  /// re-pairing case SPEC §4.4 describes for a wiped and reset phone — is not
  /// this method's job: a caller that wants that composes [revoke] and
  /// [add].
  Future<void> add(PairedDevice device) async {
    final devices = await load();
    for (final existing in devices) {
      if (existing.name == device.name) {
        throw PairedDeviceCollisionException(
          'a device named "${device.name}" is already paired',
        );
      }
      if (existing.deviceId == device.deviceId) {
        throw PairedDeviceCollisionException(
          'device ${device.deviceId} is already paired, as '
          '"${existing.name}"',
        );
      }
    }
    await _save([...devices, device]);
  }

  /// Removes the device pinned to [deviceId].
  ///
  /// SPEC §4.4: "Revocation is local, not a network operation" — this writes
  /// only this host's store, and takes effect starting with the next call any
  /// caller makes to [byDeviceId] or [load], per the class doc comment's
  /// freshness guarantee. Throws [PairedDeviceNotFoundException] if no device
  /// with that id is paired, rather than silently doing nothing — a caller
  /// asking to revoke a specific device should be told when that device was
  /// never there to remove.
  Future<void> revoke(String deviceId) async {
    final devices = await load();
    final remaining = devices.where((d) => d.deviceId != deviceId).toList();
    if (remaining.length == devices.length) {
      throw PairedDeviceNotFoundException(deviceId);
    }
    await _save(remaining);
  }

  /// Records [address] as the last-known address for the device pinned to
  /// [deviceId] (SPEC §4.4: "overwritten on every successful connection").
  /// Throws [PairedDeviceNotFoundException] if no device with that id is
  /// paired — a connection cannot have succeeded against a device this store
  /// does not know.
  Future<void> recordConnection(String deviceId, PeerAddress address) async {
    final devices = await load();
    final index = devices.indexWhere((d) => d.deviceId == deviceId);
    if (index == -1) throw PairedDeviceNotFoundException(deviceId);
    devices[index] = devices[index].withLastKnownAddress(address);
    await _save(devices);
  }

  /// Replaces the certificate on file for the device pinned to [deviceId]
  /// with [certificatePem] — the renewal write SPEC §4.4 describes: a peer
  /// that presented a certificate carrying the pinned key but different
  /// bytes has renewed, and the bytes on file are what this host installs
  /// as a trust anchor when *it* is the server, so they have to follow.
  /// Refused, as a [PairedDeviceCollisionException], when [certificatePem]
  /// carries a different key: that is not a renewal but another device, and
  /// the pin must not move. Same read-replace-rewrite shape as
  /// [recordConnection].
  Future<void> recordCertificate(String deviceId, String certificatePem) async {
    final devices = await load();
    final index = devices.indexWhere((d) => d.deviceId == deviceId);
    if (index == -1) throw PairedDeviceNotFoundException(deviceId);
    final renewed = devices[index].withCertificatePem(certificatePem);
    if (renewed.deviceId != deviceId) {
      throw PairedDeviceCollisionException(
        'certificate offered for $deviceId carries a different key '
        '(${renewed.deviceId})',
      );
    }
    devices[index] = renewed;
    await _save(devices);
  }

  /// Grants the device pinned to [deviceId] an additional replica root —
  /// pairing's second step (SPEC §4.4, task 83800f), and what `dsync pair
  /// grant` (task bc68c7) calls. [rootPath] is expected already expanded
  /// (`Location.expandedPath`), the same form
  /// [PairedDevice.agreedReplicaRoots] is documented to hold; this does not
  /// expand it itself.
  ///
  /// Same shape as [recordConnection]: read, replace the one entry
  /// ([PairedDevice.withAdditionalRoot]), rewrite atomically. Deliberately
  /// not [revoke] followed by [add] — that would lose [PairedDevice.pairedAt]
  /// (a fresh [add] always stamps "now") and briefly leave the store with no
  /// entry for the device between the two writes, neither of which this
  /// method's single read-modify-write does. Throws
  /// [PairedDeviceNotFoundException] if no device with that id is paired, the
  /// same as [recordConnection] — a root cannot be granted to a pairing that
  /// does not exist.
  Future<void> grant(String deviceId, String rootPath) async {
    final devices = await load();
    final index = devices.indexWhere((d) => d.deviceId == deviceId);
    if (index == -1) throw PairedDeviceNotFoundException(deviceId);
    devices[index] = devices[index].withAdditionalRoot(rootPath);
    await _save(devices);
  }

  /// Withdraws [rootPath] from the device pinned to [deviceId] — the
  /// withdrawal half of [grant], and the only way back from one that does not
  /// also throw the pairing away the way [revoke] does.
  ///
  /// Withdrawal is local, like the grant it undoes and like [revoke]: nothing
  /// is told to the peer, and it takes effect starting with the next
  /// [byDeviceId] or [load] a `hello` handler makes, per the class doc
  /// comment's freshness guarantee. A run already in flight over that root
  /// keeps its channel — the check happens at `hello`, not per request.
  ///
  /// Throws [PairedDeviceNotFoundException] if no device with that id is
  /// paired, the same as [grant]. A [rootPath] that was never granted is
  /// *not* an error: the caller asked for this device not to serve that root,
  /// and it does not. [PairedDevice.withoutRoot] says the same.
  Future<void> revokeRoot(String deviceId, String rootPath) async {
    final devices = await load();
    final index = devices.indexWhere((d) => d.deviceId == deviceId);
    if (index == -1) throw PairedDeviceNotFoundException(deviceId);
    devices[index] = devices[index].withoutRoot(rootPath);
    await _save(devices);
  }

  /// Relabels the device pinned to [deviceId] as [name] (SPEC §4.4: the name
  /// is this host's own, local, and not agreed with the peer).
  ///
  /// Rejected, not silently disambiguated, when [name] is already another
  /// paired device's — the same uniqueness [add] enforces, for the same
  /// reason: `dsync pair grant <name> <path>` and `peer://<name>` address a
  /// device by it, so two entries sharing one name is an ambiguity the store
  /// must not be able to hold. Renaming a device to the name it already has
  /// is a no-op write, not a collision with itself.
  ///
  /// Throws [PairedDeviceNotFoundException] if no device with that id is
  /// paired, the same as [grant] and [recordConnection]. An empty [name] is
  /// refused by [PairedDevice]'s constructor, as it is everywhere else.
  Future<void> rename(String deviceId, String name) async {
    final devices = await load();
    final index = devices.indexWhere((d) => d.deviceId == deviceId);
    if (index == -1) throw PairedDeviceNotFoundException(deviceId);
    for (final existing in devices) {
      if (existing.name == name && existing.deviceId != deviceId) {
        throw PairedDeviceCollisionException(
          'a device named "$name" is already paired',
        );
      }
    }
    devices[index] = devices[index].withName(name);
    await _save(devices);
  }

  List<PairedDevice> _parseDocument(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('top-level document is not a JSON object');
    }
    if (decoded['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'unsupported schema version: ${decoded['schemaVersion']}',
      );
    }
    final devices = decoded['devices'];
    if (devices is! List) {
      throw const FormatException('"devices" is not a list');
    }
    return [for (final entry in devices) _deviceFromJson(entry)];
  }

  PairedDevice _deviceFromJson(Object? entry) {
    if (entry is! Map<String, dynamic>) {
      throw const FormatException('device entry is not a JSON object');
    }
    final address = entry['lastKnownAddress'];
    if (address is! Map<String, dynamic>) {
      throw const FormatException('"lastKnownAddress" is not a JSON object');
    }
    final roots = entry['agreedReplicaRoots'];
    if (roots is! List) {
      throw const FormatException('"agreedReplicaRoots" is not a list');
    }
    return PairedDevice(
      certificatePem: entry['certificatePem'] as String,
      name: entry['name'] as String,
      agreedReplicaRoots: roots.map((r) => r as String).toSet(),
      pairedAt: DateTime.parse(entry['pairedAt'] as String),
      lastKnownAddress: PeerAddress(
        host: address['host'] as String,
        port: address['port'] as int,
      ),
    );
  }

  Map<String, Object?> _deviceToJson(PairedDevice device) => {
    'certificatePem': device.certificatePem,
    'name': device.name,
    'agreedReplicaRoots': device.agreedReplicaRoots.toList(),
    'pairedAt': device.pairedAt.toIso8601String(),
    'lastKnownAddress': {
      'host': device.lastKnownAddress.host,
      'port': device.lastKnownAddress.port,
    },
  };

  /// Rewrites the whole document with exactly [devices] and no others,
  /// atomically: written to a scratch file and renamed over [_file], so a
  /// reader never sees a partially-written document and a crash mid-write
  /// leaves the previous, still-valid document in place (see the class doc
  /// comment).
  Future<void> _save(List<PairedDevice> devices) async {
    final document = {
      'schemaVersion': schemaVersion,
      'devices': [for (final device in devices) _deviceToJson(device)],
    };
    await _file.parent.create(recursive: true);
    final temp = File(tempPathFor(_file.path, _nextTempSequence++));
    try {
      // flush: true is fsync: the replacement has to be on disk before the
      // rename swaps it in, or a crash in that window loses the whole store
      // rather than one mutation — the same reasoning
      // `JsonlArchiveStore.compact` gives its own rename.
      await temp.writeAsString(jsonEncode(document), flush: true);
      await temp.rename(_file.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }
}

/// Thrown by [PairedDeviceStore.load] when [PairedDeviceStore]'s file exists
/// but cannot be read as this store's document: truncated, malformed JSON, or
/// well-formed JSON of the wrong shape or schema version. Deliberately not
/// treated as an empty set — see the class doc comment on absent vs. damaged.
class PairedDeviceStoreCorruptException implements Exception {
  final String path;
  final String detail;

  const PairedDeviceStoreCorruptException(this.path, this.detail);

  @override
  String toString() =>
      'Paired-device store at $path is corrupt and cannot be trusted as '
      'either the current set of paired devices or an empty one: $detail. '
      'Restore it from a backup, or remove it and re-pair every device.';
}

/// Thrown by [PairedDeviceStore.add] when the device being added collides
/// with one already paired, by name or by device id (SPEC §4.4).
class PairedDeviceCollisionException implements Exception {
  final String detail;

  const PairedDeviceCollisionException(this.detail);

  @override
  String toString() => 'Cannot pair device: $detail';
}

/// Thrown by [PairedDeviceStore.revoke] and [PairedDeviceStore.recordConnection]
/// when no paired device matches the given device id.
class PairedDeviceNotFoundException implements Exception {
  final String deviceId;

  const PairedDeviceNotFoundException(this.deviceId);

  @override
  String toString() => 'No paired device with id $deviceId';
}
