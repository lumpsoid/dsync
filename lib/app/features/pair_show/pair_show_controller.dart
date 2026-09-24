import 'dart:async';
import 'dart:io';

import '../../app_controller.dart';
import '../../app_settings.dart';
import '../../app_settings_store.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/enrolment_outcome.dart';
import '../../core_link/models/enrolment_update.dart';
import '../../core_link/models/pairing_window.dart';
import 'pair_show_view_state.dart';
import 'pairing_offer.dart';

/// `dsync pair show` in the Flutter head (SPEC §4.4): the core opens an
/// enrolment endpoint and a token, this offers the payload as a symbol and
/// a line, and waits for one device to redeem it.
///
/// The other half of the Pair page, and the same exchange seen from the
/// other end: there, this device reads someone else's code and dials them;
/// here, it shows its own and is dialled. Which end shows the code is a
/// question of which device has a camera and which has a keyboard, not of
/// which one is "the desktop" — so both heads can do both.
///
/// **The endpoint exists only while this window is open.** That is the
/// property SPEC §4.4 asks for — "off by default and open only for the
/// duration of one pairing operation" — and [stop], called by the page on
/// the way out, is what cancels the core's window.
///
/// **One name is asked for, and it is this side's own.** [show] takes the
/// name this device will list whoever redeems the payload under — the
/// handle the device list, a grant and a `peer://` location all address it
/// by. What the other end calls *this* device stays the other end's own
/// choice.
///
/// **Nothing is recorded until the operator confirms the device (task
/// 23344d).** A redeemed code says somebody saw it, not that they are the
/// device the operator meant. So the id derived from the certificate the
/// redeeming device presented goes on screen as [PairShowConfirming], and
/// [answerConfirmation] is the answer; declining records nothing at all.
/// The code is spent either way, so both answers end this window.
///
/// **What the wait ends on** is the core's to decide and arrives as the
/// window's last update: enrolled, declined, unanswered, expired,
/// cancelled, or failed. A connection turned away before it redeemed the
/// token (a stranger's wrong guess) does not end the window and is not
/// shown: it must not close a window the legitimate peer is still walking
/// across the room to use.
class PairShowController {
  PairShowController(this.app, {required this.bindAddress});

  final AppController app;

  /// How the address the endpoint listens on is obtained — the head's
  /// equivalent of `dsync pair show --bind` (task 2b26ac), read from
  /// Settings by the scope. The core decides what to advertise from it.
  final Future<InternetAddress> Function() bindAddress;

  /// The view state this controller renders into; owned here, disposed here.
  final PairShowViewState state = PairShowViewState();

  /// Completed when the window this controller is showing should end — the
  /// page left, or a fresh window replaced it. Guards every write, so a
  /// window's late news never lands on a later one.
  Completer<void>? _stopped;

  /// The core's session for the window on screen, while it is open.
  int? _session;

  /// Opens a pairing window that lists whoever redeems it as [peerName],
  /// and waits for its end. Any window already open is closed first.
  Future<void> show({required String peerName}) async {
    await stop();
    final stopped = _stopped = Completer<void>();
    _record(stopped, const PairShowStarting());

    final InternetAddress bindTo;
    try {
      bindTo = await bindAddress();
    } on AppSettingsStoreCorruptException catch (e) {
      // The settings file exists and cannot be read. Binding the defaults
      // instead would be reading damaged bytes as a decision the user never
      // made, so the window refuses and says what to do about the file.
      _record(stopped, PairShowFailed(e.toString()));
      return;
    }

    final PairingWindow window;
    try {
      window = await app.core.showPairing(
        name: peerName,
        bind: bindTo.address,
        servicePort: defaultPeerPort,
      );
    } on CoreFailure catch (e) {
      _record(
        stopped,
        PairShowFailed(
          'This device could not open a pairing endpoint: ${e.message}. '
          'Pair the other way round instead — scan or paste that device\'s '
          'code from the Pair page.',
        ),
      );
      return;
    }
    if (stopped.isCompleted) {
      // The page left while the endpoint was being bound: nothing is
      // watching this window, so close it rather than leave it open for its
      // token's full lifetime.
      await _cancel(window.session);
      return;
    }
    _session = window.session;
    _record(
      stopped,
      PairShowWaiting(
        PairingOffer.forPayload(
          window.payload,
          address: window.endpoint,
          expiresAt: DateTime.now().add(window.expiresIn),
        ),
      ),
    );

    try {
      await for (final update in window.updates) {
        switch (update) {
          case EnrolmentRefused():
            break;
          case EnrolmentAwaiting(:final deviceId):
            _record(
              stopped,
              PairShowConfirming(deviceId: deviceId, peerName: peerName),
            );
          case EnrolmentEnded(:final outcome):
            await _ended(outcome, stopped, window: window.expiresIn);
        }
      }
    } finally {
      if (_session == window.session) _session = null;
    }
  }

  Future<void> _ended(
    EnrolmentOutcome outcome,
    Completer<void> stopped, {
    required Duration window,
  }) async {
    switch (outcome) {
      case Enrolled(:final device):
        await _recordPaired(device.name, stopped);
      case EnrolmentDeclined():
        _record(stopped, const PairShowDeclined());
      case EnrolmentUnconfirmed():
        _record(
          stopped,
          const PairShowFailed(
            'Nobody answered for the device that used this code before it '
            'ran out, so nothing was recorded. Show a new one when you are '
            'ready to confirm it.',
          ),
        );
      case EnrolmentNotStored(:final message):
        _record(
          stopped,
          PairShowFailed(
            'The device was confirmed but could not be recorded here: '
            '$message',
          ),
        );
      case EnrolmentExpired():
        _record(stopped, PairShowExpired(window));
      case EnrolmentCancelled():
        break;
      case EnrolmentFailed(:final message):
        _record(
          stopped,
          PairShowFailed(
            'The pairing window closed: $message. The code is used up '
            'either way — show a new one and try again.',
          ),
        );
    }
  }

  /// The operator's answer to [PairShowConfirming]: whether the id on
  /// screen is the id the other device shows. Ignored when nothing is
  /// waiting for an answer.
  void answerConfirmation({required bool confirmed}) {
    final session = _session;
    if (session == null || state.status is! PairShowConfirming) return;
    unawaited(_confirm(session, confirmed));
  }

  Future<void> _confirm(int session, bool confirmed) async {
    try {
      await app.core.confirmPairing(session, accept: confirmed);
    } on CoreFailure {
      // The window already ended; its last update says how.
    }
  }

  /// Ends the window on screen, if any. Called by the page on the way out
  /// and by [show] before a fresh window.
  Future<void> stop() async {
    final stopped = _stopped;
    if (stopped != null && !stopped.isCompleted) stopped.complete();
    final session = _session;
    _session = null;
    if (session != null) await _cancel(session);
  }

  Future<void> _cancel(int session) async {
    try {
      await app.core.cancelPairing(session);
    } on CoreFailure {
      // Already closed: nothing left to cancel.
    }
  }

  Future<void> _recordPaired(String name, Completer<void> stopped) async {
    try {
      await app.refreshDevices();
    } on CoreFailure catch (e) {
      _record(
        stopped,
        PairShowFailed('Paired, but the device list could not be re-read: $e'),
      );
      return;
    }
    _record(stopped, PairShowPaired(name));
  }

  void _record(Completer<void> stopped, PairShowStatus status) {
    if (stopped.isCompleted) return;
    state.recordStatus(status);
  }

  void dispose() {
    unawaited(stop());
    state.dispose();
  }
}
