import 'enrolment_update.dart';

/// An open pairing window: the payload to show (as text and as a QR), this
/// device's id for the other side to compare, and the window's story in
/// [updates], which ends with an [EnrolmentEnded].
final class PairingWindow {
  const PairingWindow({
    required this.session,
    required this.payload,
    required this.deviceId,
    required this.endpoint,
    required this.expiresIn,
    required this.updates,
  });

  final int session;
  final String payload;
  final String deviceId;

  /// Where the window answers (`host:port`).
  final String endpoint;
  final Duration expiresIn;
  final Stream<EnrolmentUpdate> updates;
}
