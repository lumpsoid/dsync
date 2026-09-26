import '../../app_controller.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/pair_code_reading.dart';
import 'pair_code.dart';
import 'pair_view_state.dart';

/// Input methods of the Pair page: redeeming a `dsync-pair:1.0:` payload
/// another device shows (SPEC §4.4, `dsync pair accept`).
///
/// Takes the [AppController] it borrows the application — and through it
/// the core — from as a constructor argument, per the controller role in
/// `app_scope.dart`. The exchange itself is the core's; every refusal it
/// makes arrives as its own words and is shown as the outcome.
class PairController {
  PairController(this.app);

  final AppController app;

  /// The view state this controller renders into; owned here, disposed here.
  final PairViewState state = PairViewState();

  /// Takes in a text that should be a `dsync-pair:1.0:<base64>` line — read
  /// off the QR by the camera, or pasted from the clipboard — and asks the
  /// core what it says.
  ///
  /// Nothing is sent: a code arriving is an input, not a confirmation. What
  /// it read as is recorded on [PairViewState.code] for the page to show —
  /// which device, at which address — so the user can see what they are
  /// about to pair with before the exchange starts. A text that is not a
  /// payload lands as [PairCodeUnreadable] carrying the core's own message,
  /// which already tells "not a pairing payload" from "unsupported
  /// version".
  ///
  /// The outcome goes back to idle either way, so the verdict of an earlier
  /// attempt does not sit under a code that has just replaced the one it
  /// was about.
  Future<void> codeEntered(String text) async {
    final PairCodeReading reading;
    try {
      reading = await app.core.readPairCode(text);
    } on CoreFailure catch (e) {
      state.recordCode(PairCodeUnreadable(e.message));
      state.recordOutcome(const PairIdle());
      return;
    }
    state.recordCode(switch (reading) {
      ReadPairCode(:final desktopName, :final address) => PairCodeRead(
        payload: text,
        desktopName: desktopName,
        address: address,
      ),
      UnreadablePairCode(:final message) => PairCodeUnreadable(message),
    });
    state.recordOutcome(const PairIdle());
  }

  /// A fresh visit to the page: nothing from the last one is still on
  /// screen. This controller is the cached scope instance and outlives its
  /// page (`submitPayload` is asynchronous), so clearing on arrival is what
  /// the page otherwise got for free from a new instance.
  void beginPairing() => state.clear();

  /// Puts the page back to having no code — the user rejecting what they
  /// were shown, and asking for the camera or the clipboard again.
  void clearCode() {
    state.recordCode(const PairCodeMissing());
    state.recordOutcome(const PairIdle());
  }

  /// Redeems the payload the page is holding, recording the desktop as
  /// [localName] here. What the desktop calls *this* device is the
  /// desktop's own choice, made where it showed the payload.
  ///
  /// [localName] is validated first: an empty name is a field error, not an
  /// outcome, and no exchange starts until it is present. This device's own
  /// id is recorded before the exchange, not after it: the far end asks
  /// whoever is standing there to confirm the id derived from this device's
  /// certificate *while* the exchange waits, so the operator needs it on
  /// this screen then (`dsync pair accept` prints the same line at the same
  /// point).
  ///
  /// On success the new row is on the device list; the page reads
  /// [PairSucceeded] and leaves. A refusal — nothing answered, the wrong
  /// device answered, the far end said no, the name is taken here — is the
  /// core's own line.
  Future<void> submitPayload({required String localName}) async {
    final local = localName.trim();
    state.recordLocalNameError(local.isEmpty ? _localNameRequired : null);
    if (local.isEmpty) {
      state.recordOutcome(const PairIdle());
      return;
    }

    if (state.code case PairCodeRead(:final payload)) {
      state.recordOutcome(const PairSubmitting());
      await _enrol(payload, localName: local);
      return;
    }
    state.recordOutcome(const PairFailed(_codeRequired));
  }

  Future<void> _enrol(String payload, {required String localName}) async {
    try {
      state.recordOwnDeviceId((await app.core.showIdentity()).deviceId);
      await app.core.acceptPairing(code: payload, name: localName);
    } on CoreFailure catch (e) {
      state.recordOutcome(PairFailed(e.message));
      return;
    }
    try {
      await app.refreshDevices();
    } on CoreFailure catch (e) {
      state.recordOutcome(
        PairFailed('Paired, but the device list could not be re-read: $e'),
      );
      return;
    }
    state.recordOutcome(PairSucceeded(localName));
  }

  /// Re-validates the name field as the user types, so its error line goes
  /// away the moment it is fixed rather than at the next submit.
  void localNameEdited(String value) => state.recordLocalNameError(
    value.trim().isEmpty ? _localNameRequired : null,
  );

  void dispose() => state.dispose();
}

const _localNameRequired = 'Give the desktop a name to show it as here.';
const _codeRequired =
    'Scan or paste a pairing code from `dsync pair show` first.';
