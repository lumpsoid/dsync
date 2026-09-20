import 'dart:io';

import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';

import '../../app_bootstrap.dart';
import '../../app_controller.dart';
import 'pair_code.dart';
import 'pair_view_state.dart';

/// The enrolment exchange as [PairController] takes it: the exact shape of
/// `enrolWithPeer` (`dsync_core/identity/enrolment_client.dart`), so the
/// scope passes that function itself.
///
/// A callback rather than an interface, for the reason `RunSync`
/// (`lib/cli/run/sync_runner.dart`) and `RunController`'s `Presenter` give:
/// the real one opens a `SecureSocket`, which no unit test can run, and a
/// one-method interface over a single top-level function would be a rename
/// of it. A test hands in a closure that records its arguments and throws
/// whichever of the exchange's failures the test is about.
typedef EnrolWithPeer = Future<void> Function({
  required PairingPayload payload,
  required DeviceIdentity ownIdentity,
  required String proposedName,
  required String localName,
  required PairedDeviceStore pairedDeviceStore,
});

/// Input methods of the Pair page: enrolling against a `dsync-pair:v1:`
/// payload (SPEC §4.4).
///
/// Takes the [AppController] it borrows the application from and the
/// [EnrolWithPeer] it redeems the payload through as constructor arguments,
/// per the controller role in `app_scope.dart`. Both are required; the
/// scope names the real `enrolWithPeer`, so a fake cannot arrive by
/// omission in production any more than a real socket can in a test.
///
/// Every failure of the exchange is turned into a line on
/// [PairViewState.outcome] here, not in the page: which exception it was
/// decides what the user is told to do next, and that is a decision, not a
/// rendering. See [submitPayload] for the mapping.
class PairController {
  PairController(this.app, {required this.enrol});

  final AppController app;
  final EnrolWithPeer enrol;

  /// The view state this controller renders into; owned here, disposed here.
  final PairViewState state = PairViewState();

  /// Takes in a text that should be a `dsync-pair:v1:<base64>` line — read
  /// off the QR by the camera, or pasted from the clipboard — and decides
  /// what it is. The one place a payload is decoded.
  ///
  /// Nothing is sent: a code arriving is an input, not a confirmation. What
  /// it decoded to is recorded on [PairViewState.code] for the page to show
  /// — which device, at which address — so the user can see what they are
  /// about to pair with before the exchange starts, and can change either
  /// name first. A text that is not a payload lands as
  /// [PairCodeUnreadable] carrying `PairingPayload.decode`'s own message,
  /// which is already specific: "not a dsync pairing payload" and
  /// "unsupported version" are different problems with different fixes.
  ///
  /// The outcome goes back to idle either way, so the verdict of an earlier
  /// attempt does not sit under a code that has just replaced the one it
  /// was about.
  void codeEntered(String text) {
    try {
      state.recordCode(PairCodeRead(PairingPayload.decode(text)));
    } on FormatException catch (e) {
      state.recordCode(PairCodeUnreadable(e.message));
    }
    state.recordOutcome(const PairIdle());
  }

  /// Puts the page back to having no code — the user rejecting what they
  /// were shown, and asking for the camera or the clipboard again.
  void clearCode() {
    state.recordCode(const PairCodeMissing());
    state.recordOutcome(const PairIdle());
  }

  /// Redeems the payload the page is holding ([PairViewState.code], put
  /// there by [codeEntered]), recording the desktop as [localName] here and
  /// asking it to record this device as [proposedName] (SPEC §4.4: each
  /// side names the other for itself, so the two need not agree).
  ///
  /// Names are validated first, without touching the payload: an empty
  /// name is a field error, not an outcome — the outcome goes back to idle
  /// so an earlier verdict does not sit under the new attempt — and no
  /// exchange starts until both are present. Then, in order:
  ///
  /// - No readable code. The page does not offer the button in that state,
  ///   so this is the belt to its braces rather than a line anyone should
  ///   see.
  /// - `SocketException`: nothing answered at the payload's address hint.
  ///   Names the host and port so the user can check it is the right
  ///   network.
  /// - `HandshakeException`: whatever answered is not the device the payload
  ///   pinned. Not the TLS 1.3 asymmetry `SocketChannel.connectSecure`
  ///   documents — `enrolWithPeer`'s doc comment explains why — so it can be
  ///   reported as exactly what it is.
  /// - `EnrolmentRefusedException`: the far end took the connection and said
  ///   no — token burned or expired, or [proposedName] rejected. Its
  ///   `reason` is the far end's own words and is shown verbatim.
  /// - `PairedDeviceCollisionException`: [localName] or the far end's id
  ///   already exists in this device's store. Per `enrolWithPeer`, this is
  ///   thrown *after* the far end has recorded us, so the pairing is
  ///   half-done and the message says so: the desktop now trusts this
  ///   device, this device does not trust it back, the token is burned, and
  ///   the fix is a different local name against a fresh `dsync pair show`.
  ///
  /// On success `AppController.refreshDevices` shows the new row; the page
  /// reads [PairSucceeded], says so in the desktop's name, and leaves. The
  /// name on the outcome is [localName] trimmed — what the desktop was
  /// recorded as here, and so what the new row shows it as. A store that
  /// went corrupt between the add and the re-read is reported as "paired,
  /// but" — the pairing itself held — with `core`'s own line naming the
  /// file.
  Future<void> submitPayload({
    required String localName,
    required String proposedName,
  }) async {
    final local = localName.trim();
    final proposed = proposedName.trim();
    state.recordNameErrors(
      localName: local.isEmpty ? _localNameRequired : null,
      proposedName: proposed.isEmpty ? _proposedNameRequired : null,
    );
    if (local.isEmpty || proposed.isEmpty) {
      state.recordOutcome(const PairIdle());
      return;
    }

    if (state.code case PairCodeRead(:final payload)) {
      state.recordOutcome(const PairSubmitting());
      await _enrol(payload, localName: local, proposedName: proposed);
      return;
    }
    state.recordOutcome(const PairFailed(_codeRequired));
  }

  /// The exchange itself, over a payload that has already decoded and names
  /// that have already validated. Split out so [submitPayload] reads as the
  /// two questions it asks before committing to it.
  Future<void> _enrol(
    PairingPayload payload, {
    required String localName,
    required String proposedName,
  }) async {
    final identity = await app.loadOrCreateIdentity();
    final store = await app.pairedDevices;
    final address = '${payload.address.host}:${payload.address.port}';
    try {
      await enrol(
        payload: payload,
        ownIdentity: identity,
        proposedName: proposedName,
        localName: localName,
        pairedDeviceStore: store,
      );
    } on SocketException catch (e) {
      state.recordOutcome(
        PairFailed(
          'Could not reach the desktop at $address: ${e.message}. Check '
          'that both devices are on the same network and that `dsync pair '
          'show` is still running there.',
        ),
      );
      return;
    } on HandshakeException {
      state.recordOutcome(
        PairFailed(
          'The device that answered at $address is not the one this '
          'payload names. Either the payload is stale or something else is '
          'listening there — get a fresh payload from `dsync pair show`.',
        ),
      );
      return;
    } on EnrolmentRefusedException catch (e) {
      state.recordOutcome(
        PairFailed(
          'The desktop refused this pairing: ${e.reason}. Run `dsync pair '
          'show` again for a fresh payload.',
        ),
      );
      return;
    } on PairedDeviceCollisionException catch (e) {
      state.recordOutcome(
        PairFailed(
          'This pairing is half-done: the desktop accepted and now trusts '
          'this device, but it could not be recorded here (${e.detail}). '
          'The token is used up, so run `dsync pair show` again on the '
          'desktop and pair with a different name for it.',
        ),
      );
      return;
    }

    try {
      await app.refreshDevices();
    } on PairedDeviceStoreCorruptException catch (e) {
      state.recordOutcome(
        PairFailed('Paired, but the device list could not be re-read: $e'),
      );
      return;
    }
    state.recordOutcome(PairSucceeded(localName));
  }

  /// The desktop's name as it is being typed.
  ///
  /// The same rule [submitPayload] applies, applied when the field changes
  /// rather than only when a submit is refused: the page fills this field in
  /// from the payload the moment one is readable, so the only way it is ever
  /// empty is that the user emptied it — and being told that at the keyboard
  /// beats being told it after a tap that did nothing. Only this field's
  /// line moves; the other field's verdict is whatever its own last edit or
  /// the last submit made it.
  void localNameEdited(String value) => state.recordLocalNameError(
    value.trim().isEmpty ? _localNameRequired : null,
  );

  /// This device's name as it is being typed; see [localNameEdited].
  void proposedNameEdited(String value) => state.recordProposedNameError(
    value.trim().isEmpty ? _proposedNameRequired : null,
  );

  /// What this device calls itself: the common name in its own certificate,
  /// which the This device page's rename writes and describes as "the name
  /// offered to devices you pair with from now on" — so this is the name the
  /// page offers as the proposed one, and that promise is kept.
  ///
  /// Empty when there is no name to read: before bootstrap has produced an
  /// identity, and for a certificate whose subject carries no readable name
  /// (see `DeviceIdentityRow.name`). The page, not this getter, decides what
  /// to offer instead — the fallback reads the platform, and this class is
  /// testable with plain values.
  String get ownName => switch (app.state.bootstrap) {
    AppBootstrapReady(:final identity) => identity.name,
    _ => '',
  };

  void dispose() => state.dispose();
}

const _localNameRequired = 'Give the desktop a name to show it as here.';
const _proposedNameRequired =
    'Give this device a name for the desktop to '
    'show it as.';
const _codeRequired =
    'Scan or paste a pairing code from `dsync pair show` first.';
