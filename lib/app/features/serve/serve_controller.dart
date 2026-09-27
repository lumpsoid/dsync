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
/// session an idle timeout can cut in half — unless the Settings page
/// turned that off, read when serving starts.
///
/// **Stopping stops accepting.** A session already connected when [stop]
/// lands runs to its end in the core (it holds the replica's lock and is
/// mid-exchange); nothing new is accepted. [stop] asks the core and keeps
/// listening: the page shows the core's last view, which says how serving
/// ended.
///
/// **Where serving stands is one value** ([_Lifecycle]): idle, binding,
/// binding for a page that already left, serving, stopping, or disposed.
/// A session's views are shown only while it is the one serving or
/// stopping, so a stopped session's late news never lands on a fresh one.
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
    required this.keepScreenAwake,
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

  /// Whether the Settings page wants the screen held while serving, read
  /// once per [start] like [bindAddress]. Throws `AppSettingsStoreException`
  /// when the settings file cannot be read.
  final Future<bool> Function() keepScreenAwake;

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
      if (row.agreedRoots.isEmpty) row.name,
  ];

  _Lifecycle _lifecycle = const _Idle();
  bool _screenHeld = false;
  bool _screenWanted = false;

  /// The port the core bound, while serving.
  int? get boundPort => switch (_lifecycle) {
    _Serving(:final session) => session.port,
    _Idle() || _Binding() || _Abandoned() || _Stopping() || _Disposed() => null,
  };

  /// Starts serving on the stored bind address. A second call while serving
  /// or binding is ignored; one while the last session is still stopping
  /// starts afresh, and that session's last view is not shown.
  Future<void> start() async {
    switch (_lifecycle) {
      case _Idle():
        break;
      case _Stopping(:final views):
        unawaited(views.cancel());
      case _Binding() || _Abandoned() || _Serving() || _Disposed():
        return;
    }
    _moveTo(const _Binding());
    state.recordStatus(const ServeStarting());
    _screenWanted = await _readKeepScreenAwake();
    final InternetAddress address;
    try {
      address = await bindAddress();
    } on AppSettingsStoreException catch (e) {
      // Binding the defaults instead would be reading damaged bytes as a
      // decision the user never made — the same refusal
      // `PairShowController.show` makes over the same file.
      _bindFailed(ServeFailed(e.toString()));
      return;
    }

    final ServeSession session;
    try {
      session = await app.core.startServe(bind: address.address, port: port);
    } on CoreFailure catch (e) {
      _bindFailed(ServeFailed(_bindRefusal(address, e.message)));
      return;
    }
    // Only this call leaves binding: a stop meanwhile abandoned it, and a
    // dispose ended the page.
    final now = _lifecycle;
    if (now is _Binding) {
      _moveTo(_Serving(session, _listen(session)));
      return;
    }
    // Stopped or left while the socket was being bound: stop it rather
    // than leave this device answering behind a screen that asked it not
    // to — and, for a page still here, show how the core says it ended.
    if (now is _Abandoned) _moveTo(_Stopping(session, _listen(session)));
    await _stopQuietly(session);
  }

  /// A bind refused before the core opened a session: the page's own
  /// failure, unless the page left meanwhile.
  void _bindFailed(ServeFailed failure) {
    if (_lifecycle is _Disposed) return;
    _moveTo(const _Idle());
    state.recordStatus(failure);
  }

  /// Renders [session]'s views until its last, which ends the lifecycle.
  StreamSubscription<ServeView> _listen(ServeSession session) =>
      session.views.listen(_show, onDone: () => _moveTo(const _Idle()));

  /// Renders the core's [view]: whether it answers — a listener that
  /// failed on its own is the page's failure — and one timestamped line
  /// per connection event it kept.
  void _show(ServeView view) {
    state.show(
      status: switch (view.phase) {
        ServePhaseListening(:final advertised) => ServeListening(advertised),
        ServePhaseStopped() => const ServeStopped(),
        ServePhaseFailed(:final message) => ServeFailed(message),
      },
      sessions: [for (final line in view.lines) _line(line)],
    );
  }

  /// Asks the core to stop accepting and keeps listening: its last view
  /// says how serving ended. A stop while binding shows the page stopped
  /// and stops the session once the core opens it.
  Future<void> stop() async {
    switch (_lifecycle) {
      case _Serving(:final session, :final views):
        _moveTo(_Stopping(session, views));
        await _stopQuietly(session);
      case _Binding():
        _moveTo(const _Abandoned());
        state.recordStatus(const ServeStopped());
      case _Idle() || _Abandoned() || _Stopping() || _Disposed():
        break;
    }
  }

  void dispose() {
    final was = _lifecycle;
    _moveTo(const _Disposed());
    // None is awaited: a `dispose` is synchronous, and
    // `PlatformScreenWake` swallows its own failures already.
    switch (was) {
      case _Serving(:final session, :final views) ||
          _Stopping(:final session, :final views):
        unawaited(views.cancel());
        unawaited(_stopQuietly(session));
      case _Idle() || _Binding() || _Abandoned() || _Disposed():
        break;
    }
    state.dispose();
  }

  /// Moves to [next], holding the screen exactly while serving, if the
  /// Settings page wants it held.
  void _moveTo(_Lifecycle next) {
    _lifecycle = next;
    final hold = next is _Serving && _screenWanted;
    if (hold == _screenHeld) return;
    _screenHeld = hold;
    unawaited(hold ? screenWake.enable() : screenWake.disable());
  }

  /// The stored keep-awake switch. A settings file that cannot be read
  /// holds the screen, as this head always did; the bind address, read
  /// next from the same file, is what refuses it.
  Future<bool> _readKeepScreenAwake() async {
    try {
      return await keepScreenAwake();
    } on AppSettingsStoreException {
      return true;
    }
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

/// Where serving stands. One value, so the page's news, the screen and the
/// core's session cannot disagree.
sealed class _Lifecycle {
  const _Lifecycle();
}

/// Nothing bound, nothing binding.
final class _Idle extends _Lifecycle {
  const _Idle();
}

/// The bind address is being read and the socket bound.
final class _Binding extends _Lifecycle {
  const _Binding();
}

/// Binding, but stopped meanwhile: the session is stopped as soon as the
/// core opens it.
final class _Abandoned extends _Lifecycle {
  const _Abandoned();
}

/// Answering: [views] renders [session]; the screen is held.
final class _Serving extends _Lifecycle {
  const _Serving(this.session, this.views);

  final ServeSession session;
  final StreamSubscription<ServeView> views;
}

/// Asked to stop: still rendering [session] until its last view.
final class _Stopping extends _Lifecycle {
  const _Stopping(this.session, this.views);

  final ServeSession session;
  final StreamSubscription<ServeView> views;
}

/// The page left.
final class _Disposed extends _Lifecycle {
  const _Disposed();
}
