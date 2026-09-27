import '../../app_controller.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/peer_probe_outcome.dart';
import '../../paired_device_row.dart';
import '../run_setup/file_chooser.dart';
import '../run_setup/folder_picker.dart';
import 'device_detail_view_state.dart';

/// Input methods of the Device page: one paired device, and everything this
/// host decides about it (SPEC §4.4, §13) — what it is called here, which
/// of this host's replica roots it may reach, and whether it is trusted at
/// all.
///
/// Takes the [AppController] it borrows the application — and through it
/// the core — from as a constructor argument, per the controller role in
/// `app_scope.dart`. The device itself is `AppState`'s and this controller
/// reads it back through [device] by the id [select] was given —
/// cross-feature handoff carries an id, not data, so the page is opened
/// with an id and the row is loaded here.
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
/// — which is exactly where the grant does bite.
class DeviceDetailController {
  DeviceDetailController(this.app, {required this.picker});

  final AppController app;

  /// The platform's folder chooser, borrowed from Run setup rather than
  /// declared again here: it is the same question — which folder on this
  /// host — and a second interface over the same two platform channels
  /// would be a rename of this one. Used only to fill the grant field; what
  /// it hands back is a path like any other, and it is stored through the
  /// same call a typed one is.
  ///
  /// Nothing here probes the folder the way Run setup does. A grant is
  /// about *authorization*, not reachability: the root a peer will ask for
  /// may well not exist yet on the host that serves it, and refusing to
  /// record a grant because the folder is missing today would be answering
  /// a question nobody asked. The `hello` handler that compares a requested
  /// root against this set is where a missing folder is found out.
  final FolderPicker picker;

  /// The view state this controller renders into; owned here, disposed here.
  final DeviceDetailViewState state = DeviceDetailViewState();

  /// A file's chooser (D6, R4): [picker]'s folder chooser, then the core's
  /// own listing of it — a grant is authorized the same way whether it is a
  /// folder or a file.
  FileChooser get fileChooser => FileChooser(app.core, picker: picker);

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
  /// [rawAddress] is `host` or `host:port`, read by the core — the one rule
  /// for an address a user typed; one that will not parse comes back as the
  /// core's refusal. Blank text is a field error rendered here: an empty
  /// field on *this* page means nothing was typed, not "use the cached
  /// address".
  Future<void> updateAddress(String rawAddress) async {
    final id = _deviceId;
    if (id == null) return;
    final address = rawAddress.trim();
    if (address.isEmpty) {
      state.recordOutcome(
        const DeviceDetailFailed('Give an address, as host or host:port.'),
      );
      return;
    }
    await _write(
      () => app.updateDeviceAddress(id, address),
      done: 'This device will be reached at $address.',
    );
  }

  /// Dials the device where it was last reached and says which of SPEC
  /// §4.4's three answers came back: it answered and presented the pinned
  /// key, the address did not answer, or something answered with a
  /// certificate this host has not pinned.
  ///
  /// The third is told apart from the second on purpose — the address is
  /// right in that case and the fix is on the pairing, so reporting it as
  /// "unreachable" would send the user to re-type an address that was
  /// already correct.
  ///
  /// The core's probe opens and records nothing; a reachable answer is then
  /// recorded as where to dial the device next, the field a run's
  /// successful dial writes, so an address typed on this page and proved
  /// from it stops needing Run setup's per-run override.
  Future<void> testConnection() async {
    final id = _deviceId;
    final row = device;
    if (id == null || row == null) return;
    final PeerProbeOutcome result;
    try {
      result = await app.core.probePeer(id);
    } on CoreFailure catch (e) {
      state.recordOutcome(DeviceDetailFailed(e.message));
      return;
    }
    switch (result) {
      case PeerReachable(:final address):
        await _write(
          () => app.updateDeviceAddress(id, address),
          done: 'Reached ${row.name} at $address.',
        );
      case PeerUnreachable(:final message):
        state.recordOutcome(
          DeviceDetailFailed(
            'Could not reach ${row.name} at ${row.address}: $message. Check '
            'that it is awake and on the same network, or enter its address '
            'by hand.',
          ),
        );
      case PeerRefused(:final message):
        state.recordOutcome(
          DeviceDetailFailed(
            'Something answered at ${row.address}, but it did not present '
            'the certificate this device pinned for ${row.name}: $message',
          ),
        );
    }
  }

  /// Records that the user compared this host's id for the device against
  /// the id the device itself shows, and found them equal (SPEC §4.4).
  ///
  /// The comparison itself happens on two screens and in the user's head —
  /// nothing here dials anything or could check it, which is exactly why it
  /// is worth recording: it is the one fact about a pairing this host cannot
  /// establish for itself. What it changes is the page and the list row.
  /// What it does not change is whether this device is trusted: that was
  /// settled by the pin at pairing time and is not this button's to move.
  Future<void> confirmDeviceId() async {
    final id = _deviceId;
    if (id == null) return;
    await _write(
      () => app.markDeviceVerified(id),
      done: 'Device id confirmed.',
    );
  }

  /// The other answer to the same question: the id on the peer's screen is
  /// not the id this host pinned.
  ///
  /// Writes nothing — there is no "failed verification" to record, and a
  /// pairing the user cannot vouch for is not a different pairing, it is one
  /// they should throw away. So this says so, and leaves the revoking to the
  /// user: it is one tap further down the same page, behind its own
  /// confirmation, and doing it for them here would revoke on a user who
  /// tapped the wrong button while comparing two long strings.
  void reportDeviceIdMismatch() {
    final row = device;
    if (row == null) return;
    state.recordOutcome(
      DeviceDetailFailed(
        'The id ${row.name} shows is not the id pinned here. Whatever this '
        'pairing reaches, it is not the device you meant to pair with — '
        'revoke it below and pair again, in person.',
      ),
    );
  }

  /// Takes a confirmation back off this device — for one made in haste, or
  /// against the wrong screen. The pairing is left exactly as trusted as it
  /// was.
  Future<void> clearVerification() async {
    final id = _deviceId;
    if (id == null) return;
    await _write(
      () => app.clearDeviceVerification(id),
      done: 'Confirmation cleared.',
    );
  }

  /// Authorizes this device to reach [rawPath] on this host — pairing's
  /// second step (SPEC §4.4), the same write `dsync pair grant` makes.
  ///
  /// The core expands [rawPath] exactly as that command does, so the
  /// stored string is the one a `hello` handler compares a requested root
  /// against byte for byte; a path that will not parse is the core's
  /// refusal.
  Future<void> grantRoot(String rawPath) async {
    final id = _deviceId;
    if (id == null) return;
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      state.recordOutcome(const DeviceDetailFailed('Give a folder to share.'));
      return;
    }
    await _write(
      () => app.grantRoot(id, trimmed),
      done: 'Sharing $trimmed with this device.',
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
  /// A store that has gone unreadable since the list was last read lands
  /// on [DeviceDetailFailed] rather than escaping, the same as on the
  /// Devices page: the message — the core's own, naming the file — is what
  /// the user needs to act on, and the row already on screen is the last
  /// good one.
  Future<void> _write(
    Future<String?> Function() op, {
    required String done,
  }) async {
    final String? failure;
    try {
      failure = await op();
    } on CoreFailure catch (e) {
      state.recordOutcome(DeviceDetailFailed(e.message));
      return;
    }
    state.recordOutcome(
      failure == null ? DeviceDetailDone(done) : DeviceDetailFailed(failure),
    );
  }

  void dispose() => state.dispose();
}
