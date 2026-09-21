import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/advertisable_address.dart';
import 'package:dsync/dsync_core/identity/enrolment_listener.dart';
import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';

import '../../app_controller.dart';
import '../../app_settings_store.dart';
import 'pair_show_view_state.dart';
import 'pairing_offer.dart';

/// Binding the enrolment endpoint, as [PairShowController] takes it: the
/// arguments `EnrolmentListener.bind` needs, including the address to listen
/// on, with only the port left to the function itself (ephemeral, always —
/// see [bindEnrolmentListenerOnThisDevice]).
///
/// A callback rather than an interface, for the reason [EnrolWithPeer] in
/// `pair_controller.dart` gives: the real one binds a `RawServerSocket`,
/// and a one-method interface over a single static method would be a rename
/// of it. A test hands in a closure that binds the same real listener on the
/// loopback interface instead.
///
/// [address] is passed rather than defaulted (task 2b26ac): which address
/// this device listens on is the head's equivalent of `dsync pair show
/// --bind`, and a parameter with a default is a decision a call site can
/// keep making by omission.
typedef BindEnrolmentListener = Future<EnrolmentListener> Function({
  required InternetAddress address,
  required DeviceIdentity ownIdentity,
  required String peerName,
  required Uint8List token,
  required DateTime tokenExpiresAt,
  required PairedDeviceStore pairedDeviceStore,
  required ConfirmEnrolment confirm,
  required EnrolmentErrorHandler onError,
});

/// The production [BindEnrolmentListener]: wherever [address] says, on an
/// ephemeral port.
///
/// Ephemeral for the reason `PairShowCommand.port` documents: this endpoint
/// is a one-shot distinct from SPEC §4.4's fixed 28771 (which is the
/// *paired-replica* listener's port), so there is no number to coordinate
/// and nothing to collide with. The port it actually landed on is read back
/// off the bound socket and carried inside the payload.
Future<EnrolmentListener> bindEnrolmentListenerOnThisDevice({
  required InternetAddress address,
  required DeviceIdentity ownIdentity,
  required String peerName,
  required Uint8List token,
  required DateTime tokenExpiresAt,
  required PairedDeviceStore pairedDeviceStore,
  required ConfirmEnrolment confirm,
  required EnrolmentErrorHandler onError,
}) => EnrolmentListener.bind(
  address,
  0,
  ownIdentity: ownIdentity,
  peerName: peerName,
  token: token,
  tokenExpiresAt: tokenExpiresAt,
  pairedDeviceStore: pairedDeviceStore,
  confirm: confirm,
  onError: onError,
);

/// `dsync pair show` in the Flutter head (SPEC §4.4): generate a token, bind
/// the enrolment endpoint, offer this device's payload as a symbol and a
/// line, and wait for one device to redeem it.
///
/// The other half of the Pair page, and the same exchange seen from the
/// other end: there, this device reads someone else's code and dials them;
/// here, it shows its own and is dialled. Which end shows the code is a
/// question of which device has a camera and which has a keyboard, not of
/// which one is "the desktop" — so both heads can do both.
///
/// **The endpoint exists only while this window is open.** That is the
/// property SPEC §4.4 asks for — "off by default and open only for the
/// duration of one pairing operation" — and it is [stop], called by the page
/// on the way out, plus the `finally` in [show], that make it true here;
/// `PairShowCommand` does the same with its signal trap. Nothing else in the
/// head binds a listener (SPEC §16: the head serves no replica), and this
/// one accepts exactly one enrolment by construction of the token gate.
///
/// **One name is asked for, and it is this side's own.** [show] takes the
/// name this device will list whoever redeems the payload under — the
/// handle the device list, a grant and a `peer://` location all address it
/// by. It is chosen here rather than proposed by the enrolling device for
/// the reason `EnrolmentRequest`'s doc comment gives: a name the far end
/// picked is a name whoever won the enrolment race picked, and the name
/// collision that follows is one the operator resolves by renaming their
/// *own* device. What the other end calls *this* device stays the other
/// end's own choice (`PairController.submitPayload` there, or
/// `dsync pair accept --name`), which is why this side asks for one name
/// and the Pair page asks for two.
///
/// **Nothing is recorded until the operator confirms the device (task
/// 23344d).** A redeemed code says somebody saw it, not that they are the
/// device the operator meant — SPEC §4.4 says plainly that a leaked payload
/// lets a stranger try, and the token being single-use only makes that
/// *visible*. So the id derived from the certificate the redeeming device
/// presented goes on screen as [PairShowConfirming], against the id that
/// device shows on its own, and [answerConfirmation] is the answer;
/// declining records nothing at all. The code is spent either way, so both
/// answers end this window and the retry is a fresh one.
///
/// **What the wait ends on**, raced rather than polled: the listener
/// reporting the one enrolment it can accept, a refusal that happened after
/// the real token was already spent, the token's own expiry, and the page
/// leaving. A wrong-token guess is deliberately not one of them —
/// [enrolmentTokenRejectedReason] is filtered out — because a stranger's
/// failed probe must not close a window the legitimate peer is still walking
/// across the room to use. `PairShowCommand`'s doc comment carries the same
/// reasoning at length.
class PairShowController {
  PairShowController(
    this.app, {
    required this.bind,
    required this.bindAddress,
    this.advertisableAddress = preferredAdvertisableAddress,
    this.servicePort = PeerAddress.defaultPort,
    this.window = defaultEnrolmentTokenTtl,
  });

  final AppController app;

  /// How the endpoint is bound; the scope names the real one.
  final BindEnrolmentListener bind;

  /// How the address the endpoint listens on is obtained — the head's
  /// equivalent of `dsync pair show --bind` (task 2b26ac), named once at
  /// the composition root (`PairShowScope`) rather than defaulted here.
  ///
  /// A callback rather than a value because it is now a user's setting,
  /// read from disk, and a window must bind what the Settings page last
  /// stored rather than what this process started with. Awaited at the top
  /// of [show], so the whole of a window sees one address.
  ///
  /// `0.0.0.0` by default, the same default the CLI's flag has and for the
  /// same reason: `::` would also accept IPv4-mapped connections, but it
  /// fails outright where IPv6 is disabled, and a silent fallback is the
  /// one thing worse than failing. A non-wildcard address is also what the
  /// payload advertises — see [chosenAdvertisableHost] — so "listen only on
  /// the tunnel" and "advertise the tunnel" stay one decision.
  ///
  /// No default here, so no call site can acquire an address by omission.
  final Future<InternetAddress> Function() bindAddress;

  /// This device's own best-effort advertisable address (SPEC §4.4's address
  /// hint) — see [preferredAdvertisableAddress]'s own doc comment.
  /// Overridable so a test can pin it rather than depend on the machine's
  /// real interfaces.
  final Future<String?> Function() advertisableAddress;

  /// Which port the payload tells the other device to dial *afterwards* —
  /// where this device's `dsync agent --serve` answers, not the enrolment
  /// endpoint bound below, which is gone the moment this window closes.
  /// `dsync pair show --serve-port` is the CLI's way of saying the same
  /// thing; the head has no field for it because it has no way to run an
  /// agent on anything but the default yet.
  final int servicePort;

  /// How long a code stays redeemable (SPEC §4.4's short window).
  /// [defaultEnrolmentTokenTtl] everywhere but a test, which shortens it so
  /// the expiry path can be asserted in milliseconds rather than minutes.
  final Duration window;

  /// The view state this controller renders into; owned here, disposed here.
  final PairShowViewState state = PairShowViewState();

  /// The open window's endpoint, while there is one. Held so [stop] can
  /// close it from outside the [show] call that bound it.
  EnrolmentListener? _listener;

  /// Completed by [stop]: the arm of [show]'s race that means "the page is
  /// gone", and the flag that keeps a late outcome from being recorded into
  /// a view state nobody is reading any more.
  Completer<void>? _stopped;

  /// The question on screen, while there is one: completed by
  /// [answerConfirmation] with what the operator tapped, or by [stop] with
  /// `false` so a page that leaves mid-question refuses rather than leaving
  /// the far end's socket waiting out the whole window.
  Completer<bool>? _confirmation;

  /// Opens a pairing window and waits out its token.
  ///
  /// Called by the page once the operator has said what to call the device
  /// they are about to pair, and again after a window that ended — a token
  /// is single-use and time-bounded, so "try again" is always a fresh
  /// window rather than a retry of the old one, and the name can be a
  /// different one that time (which is the fix for a refusal that named a
  /// collision). A second call while one is open closes the first, so two
  /// endpoints can never be bound at once.
  ///
  /// Every way this ends lands on [PairShowViewState.status]: paired,
  /// expired, or failed with the line that names the remedy. The one
  /// exception is the page leaving ([stop]), which records nothing because
  /// there is nobody left to read it.
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

    final identity = await app.loadOrCreateIdentity();
    final pairedDeviceStore = await app.pairedDevices;
    final token = generateEnrolmentToken();
    final expiresAt = DateTime.now().add(window);

    // Completed when a refusal happened *after* the real token was redeemed
    // — see the class doc comment. Once the token is burned no later
    // connection can succeed, so continuing to wait out the window would
    // only make the user sit through five minutes for an answer that is
    // already known.
    final refused = Completer<String>();

    // Set the moment a confirmation is asked for, which is the observable
    // form of "the token has been redeemed": from then on the expiry timer
    // below must not fire, because "nothing used this code" has stopped
    // being true and the outcome is whatever the operator answers.
    var redeemed = false;
    // Which of the two refusals this window ended in, when it ended in one.
    // The operator saying no is the feature working and gets its own words;
    // anything else is reported as the far end being turned away.
    var declined = false;

    final EnrolmentListener listener;
    try {
      listener = await bind(
        address: bindTo,
        ownIdentity: identity,
        peerName: peerName,
        token: token,
        tokenExpiresAt: expiresAt,
        pairedDeviceStore: pairedDeviceStore,
        confirm: (deviceId) async {
          redeemed = true;
          final confirmed = await _askConfirmation(
            stopped,
            deviceId: deviceId,
            peerName: peerName,
          );
          declined = !confirmed;
          return confirmed;
        },
        onError: (error, _) {
          if (error is EnrolmentRefusedException &&
              error.reason != enrolmentTokenRejectedReason &&
              !refused.isCompleted) {
            refused.complete(error.reason);
          }
        },
      );
    } on SocketException catch (e) {
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
      // The page left while the socket was being bound: nothing is watching
      // this window, so close it rather than leave it open for its token's
      // full five minutes.
      await listener.close();
      return;
    }
    _listener = listener;

    final expired = Completer<void>();
    final expiryTimer = Timer(expiresAt.difference(DateTime.now()), () {
      if (!redeemed && !expired.isCompleted) expired.complete();
    });

    try {
      // What the bind address already settles, when it settles it; this
      // device's own guess across its interfaces only when it does not.
      final host =
          chosenAdvertisableHost(bindAddress: bindTo) ??
          await advertisableAddress() ??
          InternetAddress.loopbackIPv4.address;
      final address = PeerAddress(host: host, port: listener.port);
      final payload = PairingPayload(
        certificateDer: identity.certificateDer,
        address: address,
        servicePort: servicePort,
        token: token,
      );
      _record(
        stopped,
        PairShowWaiting(
          PairingOffer.forPayload(
            payload.encode(),
            address: address.text,
            expiresAt: expiresAt,
          ),
        ),
      );

      // Four ways this ends, raced against each other. Nothing polls: the
      // listener reports the one enrolment it can ever accept, rather than
      // this re-reading the store to discover what the object in front of it
      // already knows. Each arm is distinguished by the type it yields,
      // except the two that yield nothing and are told apart by which
      // completer completed.
      final outcome = await Future.any<Object?>([
        listener.enrolled,
        refused.future,
        expired.future.then((_) => null),
        stopped.future.then((_) => null),
      ]);

      if (stopped.isCompleted) return;
      if (outcome is PairedDevice) {
        await _recordPaired(outcome, stopped);
        return;
      }
      if (outcome is String) {
        _record(
          stopped,
          declined
              ? const PairShowDeclined()
              : PairShowFailed(
                  'The other device was turned away: $outcome. The code is '
                  'used up either way — show a new one and try again.',
                ),
        );
        return;
      }
      _record(stopped, const PairShowExpired());
    } finally {
      expiryTimer.cancel();
      if (_listener == listener) _listener = null;
      await listener.close();
    }
  }

  /// Puts the redeeming device's id on screen and waits for a tap.
  ///
  /// Unbounded here on purpose: `EnrolmentListener` already bounds this wait
  /// by the token's own expiry, and a second, shorter timer in the head
  /// would only be a different number for the same thing. A window already
  /// stopped answers `false` without showing anything — the page is gone,
  /// so there is nobody to ask and nothing to record.
  Future<bool> _askConfirmation(
    Completer<void> stopped, {
    required String deviceId,
    required String peerName,
  }) {
    if (stopped.isCompleted) return Future.value(false);
    final confirmation = _confirmation = Completer<bool>();
    _record(
      stopped,
      PairShowConfirming(deviceId: deviceId, peerName: peerName),
    );
    return confirmation.future;
  }

  /// The operator's answer to [PairShowConfirming]. `PairShowPage` only.
  ///
  /// Ignored when nothing is being asked, so a second tap — or one that
  /// lands after the token's window closed and `EnrolmentListener` gave up
  /// waiting — cannot complete a completer twice.
  void answerConfirmation({required bool confirmed}) {
    final confirmation = _confirmation;
    _confirmation = null;
    if (confirmation == null || confirmation.isCompleted) return;
    confirmation.complete(confirmed);
  }

  /// Closes the window, if one is open, refuses any confirmation still on
  /// screen, and stops anything it was waiting on from being recorded. Called by the page on the way out, and by
  /// [show] before it opens the next one; safe to call when nothing is
  /// open.
  Future<void> stop() async {
    final stopped = _stopped;
    if (stopped != null && !stopped.isCompleted) stopped.complete();
    // A question nobody is left to answer is a refusal: it lets the far
    // end's connection end now with a reply, instead of holding it open
    // until the token expires.
    answerConfirmation(confirmed: false);
    final listener = _listener;
    _listener = null;
    await listener?.close();
  }

  /// The enrolment happened and the store already holds it: re-read the list
  /// so the new row is there when the page leaves, and say who it was.
  ///
  /// A store that went corrupt between the add and the re-read is reported
  /// as "paired, but" — the pairing itself held — with `core`'s own line
  /// naming the file, the same way `PairController` reports it from the
  /// other end.
  Future<void> _recordPaired(
    PairedDevice device,
    Completer<void> stopped,
  ) async {
    try {
      await app.refreshDevices();
    } on PairedDeviceStoreCorruptException catch (e) {
      _record(
        stopped,
        PairShowFailed('Paired, but the device list could not be re-read: $e'),
      );
      return;
    }
    _record(stopped, PairShowPaired(device.name));
  }

  /// Records [status], unless the window it belongs to has been stopped —
  /// which is also how this page is disposed, so every write goes through
  /// here rather than risk a notification out of a torn-down view state.
  void _record(Completer<void> stopped, PairShowStatus status) {
    if (stopped.isCompleted) return;
    state.recordStatus(status);
  }

  /// The port out of an `EnrolmentListener.address`, which is `host:port`
  /// with the host already rendered — the ephemeral number the OS picked,
  /// which is what the payload has to carry.
  void dispose() {
    unawaited(stop());
    state.dispose();
  }
}
