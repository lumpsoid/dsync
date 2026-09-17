import 'dart:io';

import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/identity/pairing_payload.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';

import '../../app_controller.dart';
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

  /// Redeems [payloadText] — the `dsync-pair:v1:<base64>` line `dsync pair
  /// show` prints beside its QR — recording the desktop as [localName] here
  /// and asking it to record this device as [proposedName] (SPEC §4.4: each
  /// side names the other for itself, so the two need not agree).
  ///
  /// The entry point for a payload however it arrived. The text field calls
  /// it with what was pasted; [onPayloadScanned] — the camera's entry point,
  /// which adds only the guard a repeating source needs — calls it with what
  /// was scanned, undecoded. Decoding and validation happen here and nowhere
  /// else.
  ///
  /// Names are validated first, without touching the payload: an empty
  /// name is a field error, not an outcome — the outcome goes back to idle
  /// so an earlier verdict does not sit under the new attempt — and no
  /// exchange starts until both are present. Then, in order:
  ///
  /// - `FormatException` from `PairingPayload.decode`, before any network
  ///   call. Its own message is carried through because it is already
  ///   specific — "not a dsync pairing payload" and "unsupported version"
  ///   are different problems with different fixes.
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
  /// reads [PairSucceeded] and leaves. A store that went corrupt between
  /// the add and the re-read is reported as "paired, but" — the pairing
  /// itself held — with `core`'s own line naming the file.
  Future<void> submitPayload({
    required String payloadText,
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

    state.recordOutcome(const PairSubmitting());

    final PairingPayload payload;
    try {
      payload = PairingPayload.decode(payloadText);
    } on FormatException catch (e) {
      state.recordOutcome(PairFailed(e.message));
      return;
    }

    final identity = await app.loadOrCreateIdentity();
    final store = await app.pairedDevices;
    final address = '${payload.address.host}:${payload.address.port}';
    try {
      await enrol(
        payload: payload,
        ownIdentity: identity,
        proposedName: proposed,
        localName: local,
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
    state.recordOutcome(const PairSucceeded());
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

  /// The other input method of this page: a payload the camera read off the
  /// QR that `dsync pair show` prints beside that line.
  ///
  /// The scanner does no decoding and no validation — it hands the code's
  /// text over as it stands — so [raw] goes to [submitPayload] exactly as a
  /// pasted line would: one implementation of the exchange, one set of
  /// rendered messages, whoever produced the text. The two names come from
  /// the page because the fields holding them are the widgets'
  /// ([PairViewState] keeps only what the page displays).
  ///
  /// **The guard is what this method adds, and it is not optional.**
  /// `MobileScanner` reports every frame the code is in view, so one code in
  /// front of one camera is many calls to this method per second, each
  /// carrying the same payload — and the enrolment token inside it is
  /// single-use, burned by the desktop on its first successful redemption
  /// (SPEC §4.4). A repeat would therefore be refused by the far end, and the
  /// user would be shown [EnrolmentRefusedException]'s line — "the desktop
  /// refused this pairing" — over a pairing that had in fact just succeeded,
  /// with a template that tells them to run `dsync pair show` again. So a
  /// scan is ignored while an exchange is in flight and once one has
  /// succeeded. That is a read of [state]'s own [PairOutcome] rather than a
  /// second flag beside it: [PairSubmitting] is the first case and
  /// [PairSucceeded] the second, and a flag kept in step with them would be
  /// one more thing that can drift.
  ///
  /// A *failed* attempt is not ignored: the outcome is [PairFailed] again by
  /// then, so pointing the camera at a fresh code after a refusal works, and
  /// a scan whose names have not been filled in is answered with the field
  /// errors exactly as the paste path is. The paste path needs none of this:
  /// its button is disabled while an exchange is in flight, where the camera
  /// keeps firing whether one is running or not.
  Future<void> onPayloadScanned(
    String raw, {
    required String localName,
    required String proposedName,
  }) async {
    final outcome = state.outcome;
    if (outcome is PairSubmitting || outcome is PairSucceeded) return;
    await submitPayload(
      payloadText: raw,
      localName: localName,
      proposedName: proposedName,
    );
  }

  void dispose() => state.dispose();
}

const _localNameRequired = 'Give the desktop a name to show it as here.';
const _proposedNameRequired =
    'Give this device a name for the desktop to '
    'show it as.';
