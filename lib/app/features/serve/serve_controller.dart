import 'dart:async';
import 'dart:io';

import '../../app_controller.dart';
import '../../app_settings.dart';
import '../../app_settings_store.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/serve_event.dart';
import '../../core_link/models/serve_line.dart';
import '../../core_link/models/serve_phase.dart';
import '../../core_link/models/serve_session.dart';
import '../../core_link/models/serve_view.dart';
import '../../screen_wake.dart';
import '../../shared_folder_row.dart';
import 'serve_view_state.dart';

/// `dsync agent --serve` in the Flutter head (SPEC §4.4): answer paired
/// devices that dial *this* device, each for the folders this host granted
/// it, for as long as the Serve page is in front of the user. The core
/// serves and keeps its story; this owns when, and renders the core's
/// latest view of it.
///
/// **Serving is explicit, foreground and visible.** The listener's lifetime
/// is the page's: [start] on mount, [stop] on the way out, and stopped
/// again whenever the app is paused. That is the same property SPEC §4.4
/// already demands of the enrolment endpoint — off by default, open only
/// while somebody is looking at it — and it is the right default for a
/// phone. A background service is a different decision with its own
/// platform work, and is not this.
///
/// **Only `paused` counts, never `inactive`.** `SyncRunController`'s doc
/// comment argues this at length for the other direction, and the reason is
/// the same here: a notification shade pulled down, or a permission dialog,
/// must not drop a peer's session mid-apply.
///
/// **The screen is held awake while serving** ([ScreenWake]), for the
/// reason the Run page holds it: a session this device is serving is a
/// session an idle timeout can cut in half.
///
/// **Stopping stops accepting.** A session already connected when [stop]
/// lands runs to its end in the core (it holds the replica's lock and is
/// mid-exchange); nothing new is accepted.
///
/// **The port is fixed at [defaultPeerPort].** Both sides of a pairing
/// already record that port for each other and this head's own pairing
/// payload advertises it. [port] is a parameter only so a test can serve on
/// another one.
class ServeController {
  ServeController(
    this.app, {
    required this.bindAddress,
    required this.screenWake,
    this.port = defaultPeerPort,
  });

  final AppController app;

  /// Which address to listen on — the head's equivalent of
  /// `dsync agent --serve --bind`, read from the Settings page's Network
  /// section, the same callback `PairShowController` takes and for the
  /// same reason: a user who changes the address and then serves gets the
  /// address they just set.
  final Future<InternetAddress> Function() bindAddress;

  final ScreenWake screenWake;

  final int port;

  /// The view state this controller renders into; owned here, disposed here.
  final ServeViewState state = ServeViewState();

  /// The folders this device shares, as the Shared folders page lists them
  /// — what a peer can reach while this serves.
  List<SharedFolderRow> get folders =>
      SharedFolderRow.renderAll(app.state.devices);

  /// Paired devices that may reach nothing here: serving does not help them
  /// until a folder is shared with them.
  List<String> get devicesReachingNothing => [
    for (final row in app.state.devices)
      if (row.agreedRootLabels.isEmpty) row.name,
  ];

  ServeSession? _session;
  StreamSubscription<ServeView>? _views;

  /// The port the core bound, while serving.
  int? get boundPort => _session?.port;

  bool _starting = false;

  bool _screenHeld = false;

  bool _stopRequested = false;

  bool _disposed = false;

  /// Starts serving on the stored bind address. A second call while serving
  /// or starting is ignored.
  Future<void> start() async {
    if (_starting || _session != null) return;
    _starting = true;
    _stopRequested = false;
    state.recordStatus(const ServeStarting());
    try {
      final InternetAddress address;
      try {
        address = await bindAddress();
      } on AppSettingsStoreException catch (e) {
        // Binding the defaults instead would be reading damaged bytes as a
        // decision the user never made — the same refusal
        // `PairShowController.show` makes over the same file.
        state.recordStatus(ServeFailed(e.toString()));
        return;
      }

      final ServeSession session;
      try {
        session = await app.core.startServe(bind: address.address, port: port);
      } on CoreFailure catch (e) {
        state.recordStatus(ServeFailed(_bindRefusal(address, e.message)));
        return;
      }
      if (_stopRequested) {
        // The page left while the socket was being bound: stop it rather
        // than leave this device answering behind a screen that is gone.
        await _stopQuietly(session);
        if (!_disposed) state.recordStatus(const ServeStopped());
        return;
      }
      _session = session;
      _views = session.views.listen(_show);
    } finally {
      _starting = false;
    }
  }

  /// Renders the core's [view]: whether it answers — a listener that
  /// failed on its own is the page's failure — and one timestamped line
  /// per connection event it kept.
  void _show(ServeView view) {
    if (_disposed) return;
    final ServeStatus status;
    switch (view.phase) {
      case ServePhaseListening(:final advertised):
        status = ServeListening(advertised);
        _holdScreen(true);
      case ServePhaseStopped():
        _session = null;
        status = const ServeStopped();
        _holdScreen(false);
      case ServePhaseFailed(:final message):
        _session = null;
        status = ServeFailed(message);
        _holdScreen(false);
    }
    state.show(
      status: status,
      sessions: [for (final line in view.lines) _line(line)],
    );
  }

  /// Stops accepting and records the page as stopped.
  Future<void> stop() async {
    _stopRequested = true;
    final session = _session;
    _session = null;
    await _views?.cancel();
    _views = null;
    if (session != null) await _stopQuietly(session);
    _holdScreen(false);
    if (!_disposed) state.recordStatus(const ServeStopped());
  }

  void dispose() {
    _disposed = true;
    _stopRequested = true;
    final session = _session;
    _session = null;
    // None is awaited: a `dispose` is synchronous, and
    // `PlatformScreenWake` swallows its own failures already.
    unawaited(_views?.cancel());
    if (session != null) unawaited(_stopQuietly(session));
    _holdScreen(false);
    state.dispose();
  }

  void _holdScreen(bool wanted) {
    if (wanted == _screenHeld) return;
    _screenHeld = wanted;
    unawaited(wanted ? screenWake.enable() : screenWake.disable());
  }

  Future<void> _stopQuietly(ServeSession session) async {
    try {
      await app.core.stopServe(session.session);
    } on CoreFailure {
      // Already stopped: its stream says how.
    }
  }

  /// [line] as "HH:MM:SS  what happened", in this device's time.
  String _line(ServeLine line) {
    final at = line.at.toLocal();
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final ss = at.second.toString().padLeft(2, '0');
    final text = switch (line.event) {
      ServeRefused(:final from, :final message) => 'Refused $from: $message',
      ServeSessionStarted(:final name, :final from) =>
        '$name connected from $from',
      ServeServing(:final root) => 'Serving $root',
      ServeSessionEnded(:final name, failure: null) => '$name disconnected',
      ServeSessionEnded(:final name, :final failure?) => '$name: $failure',
    };
    return '$hh:$mm:$ss  $text';
  }

  String _bindRefusal(InternetAddress address, String cause) =>
      'This device could not answer on ${address.address}:$port: $cause. '
      'Either a `dsync agent --serve` on this machine already holds that '
      'port, or ${address.address} is not an address this device has.';
}
