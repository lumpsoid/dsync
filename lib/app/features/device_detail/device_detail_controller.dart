import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';

import '../../app_controller.dart';
import '../../paired_device_row.dart';
import '../../peer_address_text.dart';
import '../run_setup/folder_picker.dart';
import 'device_detail_view_state.dart';
import 'peer_probe.dart';
import 'root_path_expansion.dart';

/// Input methods of the Device page: one paired device, and everything this
/// host decides about it (SPEC §4.4, §13) — what it is called here, which
/// of this host's replica roots it may reach, and whether it is trusted at
/// all.
///
/// Takes the [AppController] it borrows the application from and the
/// [environment] it expands a typed path against as constructor arguments,
/// per the controller role in `app_scope.dart`. The device itself is
/// `AppState`'s and this controller reads it back through [device] by the
/// id [select] was given — cross-feature handoff carries an id, not data,
/// so the page is opened with an id and the row is loaded here.
///
/// **Every write here is local and one-sided, and that is the whole
/// design** (SPEC §4.4): a name is this host's own label, a grant is this
/// host authorizing a root it serves, and revoking is this host refusing
/// the peer's connections. None of it is sent anywhere, and the peer is
/// told nothing — which is why the page says so before each one rather
/// than leaving the user to infer it.
///
/// **A grant only bites where this host serves.** SPEC §16 keeps the
/// mobile head a client: it dials a desktop agent and binds no listener, so
/// a grant recorded on a phone authorizes a connection nothing will ever
/// make. It is still recorded, and still shown, because the store is the
/// same store `dsync agent` reads on a desktop sharing this state directory
/// (`AppPaths`) — which is exactly where the grant does bite.
class DeviceDetailController {
  DeviceDetailController(
    this.app, {
    required this.environment,
    required this.picker,
    required this.probe,
  });

  final AppController app;

  /// The dial behind [testConnection] — a socket, and the one thing on this
  /// page a test cannot run, which is what earns it an interface (see
  /// [PeerProbe]). Required rather than defaulted, as `ReplicaConnector`'s
  /// `dial` is and for the same reason: the scope names the real one, so a
  /// fake cannot arrive in production by omission.
  final PeerProbe probe;

  /// The platform's folder chooser, borrowed from Run setup rather than
  /// declared again here: it is the same question — which folder on this
  /// host — and a second interface over the same two platform channels
  /// would be a rename of this one. Used only to fill the grant field; what
  /// it hands back is a path like any other, and it is expanded and stored
  /// through the same call a typed one is.
  ///
  /// Nothing here probes the folder the way Run setup does. A grant is
  /// about *authorization*, not reachability: the root a peer will ask for
  /// may well not exist yet on the host that serves it, and refusing to
  /// record a grant because the folder is missing today would be answering
  /// a question nobody asked. The `hello` handler that compares a requested
  /// root against this set is where a missing folder is found out.
  final FolderPicker picker;

  /// The process environment a typed root path is expanded against — the
  /// same `Location.expandedPath` call `dsync pair grant` makes, so a `~`
  /// resolves to the same directory here and there and what lands in the
  /// store is the form `PairedDevice.agreedReplicaRoots` is documented to
  /// hold. A plain map, so a test expands against values it chose.
  final Map<String, String> environment;

  /// The view state this controller renders into; owned here, disposed here.
  final DeviceDetailViewState state = DeviceDetailViewState();

  String? _deviceId;

  /// Points this controller at the device the page was opened for, and
  /// clears the previous device's outcome — the scope caches one controller,
  /// so a message about the last device must not greet the next one.
  void select(String deviceId) {
    _deviceId = deviceId;
    state.recordOutcome(const DeviceDetailIdle());
  }

  /// The selected device as the list has it *now*, or `null` once it has
  /// been revoked — here or elsewhere. A getter over `AppState.devices`
  /// rather than a copy taken at [select], so the page shows the rename it
  /// just made without a second load and empties itself when the device
  /// goes.
  PairedDeviceRow? get device {
    final id = _deviceId;
    if (id == null) return null;
    for (final row in app.state.devices) {
      if (row.deviceId == id) return row;
    }
    return null;
  }

  /// Relabels this device on this host. An empty name is refused here
  /// rather than at the store: the page has a field the user can fix.
  Future<void> rename(String name) async {
    final id = _deviceId;
    if (id == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      state.recordOutcome(const DeviceDetailFailed('Give the device a name.'));
      return;
    }
    await _write(
      () => app.renameDevice(id, trimmed),
      done: 'Renamed to "$trimmed".',
    );
  }

  /// Corrects where this device is reached (SPEC §4.4's manual re-entry
  /// hatch: there is no mDNS in v1, so a peer that moved is re-entered by
  /// hand — and remembered, which is the difference between this and Run
  /// setup's per-run override).
  ///
  /// [rawAddress] is `host` or `host:port`, read by [parsePeerAddress] — the
  /// head's one rule for an address a user typed. Blank text and a text that
  /// will not parse are both field errors rendered here rather than refusals
  /// from the store: the page has a field the user can fix, and an empty
  /// field on *this* page means nothing was typed, not "use the cached
  /// address".
  Future<void> updateAddress(String rawAddress) async {
    final id = _deviceId;
    if (id == null) return;
    final PeerAddress? address;
    try {
      address = parsePeerAddress(rawAddress);
    } on FormatException catch (e) {
      state.recordOutcome(
        DeviceDetailFailed('Not a valid address: ${e.message}'),
      );
      return;
    }
    if (address == null) {
      state.recordOutcome(
        const DeviceDetailFailed('Give an address, as host or host:port.'),
      );
      return;
    }
    final target = address;
    await _write(
      () => app.updateDeviceAddress(id, target),
      done:
          'This device will be reached at '
          '${target.host}:${target.port}.',
    );
  }

  /// Dials the device at the address on file and says which of SPEC §4.4's
  /// three answers came back: it answered and presented the pinned key, the
  /// address did not answer, or something answered with a certificate this
  /// host has not pinned.
  ///
  /// The third is told apart from the second on purpose — the address is
  /// right in that case and the fix is on the pairing, so reporting it as
  /// "unreachable" would send the user to re-type an address that was
  /// already correct.
  ///
  /// Fetching and deciding are kept apart, per CLAUDE.md: everything the
  /// dial needs — the row, this device's identity, the clock — is loaded
  /// here and handed down, and [PeerProbe] only reports what the dial
  /// established. A reachable answer is then recorded through the same
  /// `recordConnection` path a run's successful dial writes, so an address
  /// typed on this page and proved from it stops needing Run setup's
  /// per-run override.
  Future<void> testConnection() async {
    final id = _deviceId;
    final row = device;
    if (id == null || row == null) return;
    final PeerAddress? address;
    try {
      address = parsePeerAddress(row.address);
    } on FormatException catch (e) {
      state.recordOutcome(
        DeviceDetailFailed('Not a valid address: ${e.message}'),
      );
      return;
    }
    if (address == null) {
      state.recordOutcome(
        const DeviceDetailFailed(
          'No address on file for this device. Enter one first.',
        ),
      );
      return;
    }
    final target = address;
    final result = await probe.probe(
      address: target,
      expectedPeerDeviceId: id,
      ownIdentity: await app.loadOrCreateIdentity(),
      now: app.now(),
    );
    final where = '${target.host}:${target.port}';
    switch (result) {
      case PeerReachable():
        await _write(
          () => app.updateDeviceAddress(id, target),
          done: 'Reached ${row.name} at $where.',
        );
      case PeerUnreachable(:final cause):
        state.recordOutcome(
          DeviceDetailFailed(
            'Could not reach ${row.name} at $where: $cause. Check that it is '
            'awake and on the same network, or enter its address by hand.',
          ),
        );
      case PeerCertificateRefused(:final detail):
        state.recordOutcome(
          DeviceDetailFailed(
            'Something answered at $where, but it did not present the '
            'certificate this device pinned for ${row.name}: $detail',
          ),
        );
    }
  }

  /// Authorizes this device to reach [rawPath] on this host — pairing's
  /// second step (SPEC §4.4), the same write `dsync pair grant` makes.
  ///
  /// [rawPath] is expanded exactly as that command expands it, through
  /// [expandRootPath] — the one rule, shared with the host-level Shared
  /// folders page — so the stored string is the one a `hello` handler
  /// compares a requested root against byte for byte; a path that will not
  /// parse is a field error, not a refusal from the store.
  Future<void> grantRoot(String rawPath) async {
    final id = _deviceId;
    if (id == null) return;
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      state.recordOutcome(const DeviceDetailFailed('Give a folder to share.'));
      return;
    }
    final String expanded;
    try {
      expanded = expandRootPath(trimmed, environment);
    } on FormatException catch (e) {
      state.recordOutcome(DeviceDetailFailed('Not a valid path: ${e.message}'));
      return;
    }
    await _write(
      () => app.grantRoot(id, expanded),
      done: 'Sharing $expanded with this device.',
    );
  }

  /// Opens the platform folder chooser and grants what comes back, or does
  /// nothing if the user dismissed it. A chooser that fails is a platform
  /// channel failing, not a folder chosen badly, and says so.
  Future<void> grantPickedRoot() async {
    final String? picked;
    try {
      picked = await picker.pick();
    } catch (error) {
      state.recordOutcome(
        DeviceDetailFailed('Could not open the folder chooser: $error'),
      );
      return;
    }
    if (picked == null) return;
    await grantRoot(picked);
  }

  /// Withdraws [rootPath] from this device — the undo of [grantRoot].
  /// [rootPath] comes off the row, already expanded, so nothing is parsed
  /// here.
  Future<void> revokeRoot(String rootPath) async {
    final id = _deviceId;
    if (id == null) return;
    await _write(
      () => app.revokeRoot(id, rootPath),
      done: 'No longer sharing $rootPath with this device.',
    );
  }

  /// Stops trusting this device (SPEC §4.4). The confirmation happens
  /// before this is called; by here the user has been told the revocation
  /// is one-sided. [device] goes `null` on success, which is what tells the
  /// page to leave.
  Future<void> revoke() async {
    final id = _deviceId;
    if (id == null) return;
    await _write(() => app.revoke(id), done: 'Revoked.');
  }

  /// The shape every write here shares: run it, and render either [done] or
  /// the refusal it came back with.
  ///
  /// A store that has gone corrupt since the list was last read lands on
  /// [DeviceDetailFailed] rather than escaping, the same as on the Devices
  /// page: the message — `core`'s own, naming the file — is what the user
  /// needs to act on, and the row already on screen is the last good one.
  Future<void> _write(
    Future<String?> Function() op, {
    required String done,
  }) async {
    final String? failure;
    try {
      failure = await op();
    } on PairedDeviceStoreCorruptException catch (e) {
      state.recordOutcome(DeviceDetailFailed(e.toString()));
      return;
    }
    state.recordOutcome(
      failure == null ? DeviceDetailDone(done) : DeviceDetailFailed(failure),
    );
  }

  void dispose() => state.dispose();
}
