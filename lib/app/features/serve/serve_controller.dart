import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/agent/agent.dart';
import 'package:dsync/dsync_core/agent/agent_listener.dart';
import 'package:dsync/dsync_core/agent/local_agent.dart';
import 'package:dsync/dsync_core/identity/advertisable_address.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';
import 'package:dsync/dsync_core/models/replica_spec.dart';
import 'package:dsync/dsync_core/models/write_path_stats.dart';

import '../../app_controller.dart';
import '../../app_paths.dart';
import '../../app_settings_store.dart';
import '../../local_replica_agent.dart';
import '../../screen_wake.dart';
import '../../shared_folder_row.dart';
import 'serve_view_state.dart';

/// Binding the replica listener, as [ServeController] takes it: the
/// arguments `AgentListener.bindSecure` needs, with nothing defaulted.
///
/// A callback rather than an interface, for the reason
/// [BindEnrolmentListener] in `pair_show_controller.dart` gives: the real
/// one binds a `RawServerSocket`, and a one-method interface over a single
/// static method would be a rename of it. The production value is
/// [AgentListener.bindSecure] itself — its optional named parameters
/// satisfy this type's required ones — and a test hands in a closure that
/// binds the same real listener on loopback, or throws the
/// [SocketException] the case is about.
typedef BindAgentListener = Future<AgentListener> Function(
  InternetAddress address,
  int port, {
  required DeviceIdentity ownIdentity,
  required PairedDeviceStore pairedDeviceStore,
  required Agent Function(ReplicaSpec spec) buildAgent,
  required SessionErrorHandler onSessionError,
  required Map<String, String> environment,
  required WritePathStats? Function(Agent agent)? writePath,
});

/// `dsync agent --serve` in the Flutter head (SPEC §4.4): answer paired
/// devices that dial *this* device, each for the folders this host granted
/// it, for as long as the Serve page is in front of the user.
///
/// The head was a replica client only — it dialled a desktop and was never
/// dialled — which is what made "a desktop cannot start a run against a
/// phone, and two phones cannot sync with each other" true. Nothing in
/// `core` had to change to lift that: `AgentListener.bindSecure` is the
/// same transport `dsync agent --serve` binds, the grant half of pairing is
/// already written and edited by this head's own Shared folders and Device
/// pages, and enrolment already records port [PeerAddress.defaultPort] for
/// the peer on both sides of a pairing. What was missing is an owner, and
/// this is it.
///
/// **Serving is explicit, foreground and visible.** The listener's lifetime
/// is the page's: [start] on mount, [stop] on the way out, and closed again
/// whenever the app is paused. That is the same property SPEC §4.4 already
/// demands of the enrolment endpoint — off by default, open only while
/// somebody is looking at it — and it is the right default for a phone. A
/// background service is a different decision with its own platform work,
/// and is not this.
///
/// **Only `paused` counts, never `inactive`.** `SyncRunController`'s doc
/// comment argues this at length for the other direction, and the reason is
/// the same here: a notification shade pulled down, or a permission dialog,
/// must not drop a peer's session mid-apply.
///
/// **The screen is held awake while the listener is bound** ([ScreenWake]),
/// for the reason the Run page holds it: a session this device is serving
/// is a session an idle timeout can cut in half, and the user who walked
/// over to the other device did not ask for that.
///
/// **Nothing here writes to the paired-device store.** The serving side
/// only ever reads it — for its trust anchors, for the peer's identity and
/// for the agreed roots — so the lost-update hazard SPEC §16 records around
/// `PairedDeviceStore`'s whole-document writes is not one this feature can
/// reach. A grant made on the Shared folders page while this is bound takes
/// effect on the peer's next connection, with nothing rebound.
///
/// **The port is fixed at [PeerAddress.defaultPort].** Both sides of a
/// pairing already record that port for each other and this head's own
/// pairing payload already advertises it, so a configurable one here would
/// need a matching field in `PairShowController.servicePort` and a way for
/// the *peer* to learn it. [port] is a parameter only so a test can bind an
/// ephemeral one — the same shape `PairShowController.servicePort` has.
class ServeController {
  ServeController(
    this.app, {
    required this.bind,
    required this.bindAddress,
    required this.environment,
    required this.screenWake,
    this.advertisableAddress = preferredAdvertisableAddress,
    this.port = PeerAddress.defaultPort,
  });

  final AppController app;

  /// How the listener is bound; the scope names the real one.
  final BindAgentListener bind;

  /// Which address to listen on — the head's equivalent of
  /// `dsync agent --serve --bind`, read from the Settings page's Network
  /// section by way of `AppSettingsStore`, the same callback
  /// `PairShowController` takes and for the same reason: a user who changes
  /// the address and then serves gets the address they just set.
  final Future<InternetAddress> Function() bindAddress;

  /// The process environment an incoming `hello`'s root is expanded
  /// against, exactly as `lib/cli/commands/agent_command.dart`'s own
  /// `_buildAgent` expands it. A plain map, so a test expands against
  /// values it chose. `AgentListener` is given the same one for the
  /// authorization check, so the path that is checked is the path that is
  /// served.
  final Map<String, String> environment;

  /// The wakelock seam, shared with the Run feature rather than declared
  /// again: it is the same fact with the same two values.
  final ScreenWake screenWake;

  /// This device's own best-effort advertisable address, for the line the
  /// user types on the other device. Overridable so a test can pin it
  /// rather than depend on the machine's real interfaces.
  final Future<String?> Function() advertisableAddress;

  /// Where paired devices dial this one. See the class doc comment for why
  /// it is not a setting.
  final int port;

  /// The view state this controller renders into; owned here, disposed
  /// here.
  final ServeViewState state = ServeViewState();

  /// One row per folder this host serves, each carrying every paired device
  /// and whether that device may reach it — the same derived list the
  /// Shared folders page draws, from `AppState.devices` and not from a copy
  /// of it.
  ///
  /// On this page because a device with no granted roots is the single most
  /// likely reason a first phone-to-phone sync fails, and by design it is
  /// silent: SPEC §4.4 requires the refusal not to distinguish "not
  /// granted" from "does not exist", so the only place the truth can be
  /// seen is this side.
  List<SharedFolderRow> get folders =>
      SharedFolderRow.renderAll(app.state.devices);

  /// This host's own names for the paired devices it has granted nothing
  /// to. They can pair, they can reach this listener, and every root they
  /// ask for is refused with a line that deliberately says nothing about
  /// why (SPEC §4.4) — so the page calls them out here, where the answer
  /// is knowable, rather than leaving the user to read an indistinguishable
  /// refusal on the other device.
  List<String> get devicesReachingNothing => [
    for (final row in app.state.devices)
      if (row.agreedRootLabels.isEmpty) row.name,
  ];

  /// The open listener, while there is one.
  AgentListener? _listener;

  /// The port the socket actually landed on, while one is bound.
  int? _boundPort;

  /// Where this device is answering, read back off the bound socket rather
  /// than remembered from [port] — `AgentListener.address` says why. They
  /// differ only for the ephemeral port a test binds, and that is exactly
  /// the case that has to be able to find out.
  int? get boundPort => _boundPort;

  /// Whether a [start] is in flight, so a second one — a resume racing a
  /// mount — cannot bind a second socket.
  bool _starting = false;

  /// Set by [stop] and cleared by [start], so a stop that lands while the
  /// socket is being bound closes what the bind returns instead of leaving
  /// it open behind a page that has gone.
  bool _stopRequested = false;

  /// Set by [dispose], so a session still finishing when the page went
  /// away cannot write a line into a view state that is already torn down
  /// — the "late event into a disposed view state" case `app_scope.dart`'s
  /// scope contract names, and the reason the listener's own callbacks are
  /// filtered rather than trusted to stop arriving.
  bool _disposed = false;

  /// Binds the listener and starts answering. Safe to call when already
  /// listening, and safe to call again after a failure — a bind that
  /// refused leaves nothing to clean up.
  ///
  /// Every way this ends lands on [ServeViewState.status]; nothing thrown
  /// here reaches the page, because a port already taken is a refusal with
  /// a remedy, not a crash.
  Future<void> start() async {
    if (_starting || _listener != null) return;
    _starting = true;
    _stopRequested = false;
    state.recordStatus(const ServeStarting());
    try {
      final InternetAddress address;
      try {
        address = await bindAddress();
      } on AppSettingsStoreCorruptException catch (e) {
        // Binding the defaults instead would be reading damaged bytes as a
        // decision the user never made — the same refusal
        // `PairShowController.show` makes over the same file.
        state.recordStatus(ServeFailed(e.toString()));
        return;
      }
      final identity = await app.loadOrCreateIdentity();
      final store = await app.pairedDevices;
      final paths = await app.paths;

      final AgentListener listener;
      try {
        listener = await bind(
          address,
          port,
          ownIdentity: identity,
          pairedDeviceStore: store,
          buildAgent: (spec) => _agentFor(spec, paths: paths),
          onSessionError: (error, _) => _recordLine('Refused: $error'),
          environment: environment,
          // SPEC §17: what this side's `writeFile` spent, carried back in
          // the `unlock` reply so the device that started the run can
          // report it. The same one line `dsync agent --serve` passes.
          writePath: (agent) => agent is LocalAgent ? agent.writePath : null,
        );
      } on SocketException catch (e) {
        state.recordStatus(ServeFailed(_bindRefusal(address, e)));
        return;
      }
      if (_stopRequested) {
        // The page left while the socket was being bound: close it rather
        // than leave this device answering behind a screen that is gone.
        await listener.close();
        state.recordStatus(const ServeStopped());
        return;
      }
      _listener = listener;
      _boundPort = _portOf(listener.address);
      state.clearSessions();
      await screenWake.enable();
      state.recordStatus(ServeListening(await _advertisedAddress(address)));
    } finally {
      _starting = false;
    }
  }

  /// Stops answering and releases the socket. Safe to call when nothing is
  /// bound, and safe to call while a [start] is still binding — that bind
  /// closes what it opened.
  ///
  /// Sessions in flight are not waited for; `AgentListener.close` says why.
  /// A peer mid-run sees its own idle deadline fail, which is the same
  /// class of outcome `SyncRunController.pause` already produces in the
  /// other direction.
  Future<void> stop() async {
    _stopRequested = true;
    final listener = _listener;
    _listener = null;
    _boundPort = null;
    if (listener != null) await listener.close();
    await screenWake.disable();
    state.recordStatus(const ServeStopped());
  }

  /// Closes the listener and the view state. The page that called
  /// `serveScope.create()` calls this.
  ///
  /// The screen wake is released here too: a page torn down while listening
  /// would otherwise leave the phone held awake by a controller nobody owns
  /// any more.
  void dispose() {
    _disposed = true;
    _stopRequested = true;
    final listener = _listener;
    _listener = null;
    _boundPort = null;
    // Neither is awaited: a `dispose` is synchronous, the socket is about
    // to be dropped with the process or the page either way, and
    // `PlatformScreenWake` swallows its own failures already.
    if (listener != null) unawaited(listener.close());
    unawaited(screenWake.disable());
    state.dispose();
  }

  /// The agent one authorized `hello` gets, and the hook that says a peer
  /// actually asked for something.
  ///
  /// `AgentListener` has already resolved who the peer is and checked this
  /// root against what they were granted, so reaching here *is* the
  /// successful case — there is no success callback on the listener to add,
  /// and this is the same fact one layer in. The root is expanded here for
  /// the reason the CLI expands it: the initiator sent it unexpanded and
  /// this host resolves `~` against its own `HOME`.
  Agent _agentFor(ReplicaSpec spec, {required AppPaths paths}) {
    final rootPath = Location.parse(spec.rootPath).expandedPath(environment);
    _recordLine('Serving $rootPath');
    return buildLocalReplicaAgent(
      paths: paths,
      rootPath: rootPath,
      profileId: spec.profileId,
      side: spec.side,
      jobs: spec.jobs,
    );
  }

  /// One line in the bounded ring, stamped with this controller's clock so
  /// a burst of probes reads as a burst rather than as one repeated line.
  void _recordLine(String text) {
    if (_disposed) return;
    final at = app.now();
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final ss = at.second.toString().padLeft(2, '0');
    state.recordSession('$hh:$mm:$ss  $text');
  }

  /// The port out of an `AgentListener.address`, which spells a network
  /// bind as `host:port` — an IPv6 host has colons of its own, so the last
  /// one is the separator.
  int _portOf(String address) =>
      int.parse(address.substring(address.lastIndexOf(':') + 1));

  /// What to type on the other device: whatever the bind address already
  /// settles, this device's own guess across its interfaces when it does
  /// not, and loopback when even that fails — the exact chain
  /// `PairShowController` uses for the pairing payload's address hint.
  Future<String> _advertisedAddress(InternetAddress bound) async {
    final host =
        chosenAdvertisableHost(bindAddress: bound) ??
        await advertisableAddress() ??
        InternetAddress.loopbackIPv4.address;
    return PeerAddress(host: host, port: _boundPort ?? port).text;
  }

  /// The sentence a refused bind shows, naming the port and both causes —
  /// the same two `AgentBindException` names for the CLI. On a desktop the
  /// first is the likely one, and saying so is the whole remedy.
  String _bindRefusal(InternetAddress address, SocketException e) {
    final cause = e.osError?.message ?? e.message;
    return 'This device could not answer on ${address.address}:$port: '
        '$cause. Either a `dsync agent --serve` on this machine already '
        'holds that port, or ${address.address} is not an address this '
        'device has.';
  }
}
