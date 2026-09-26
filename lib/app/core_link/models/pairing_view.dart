import 'paired_device_info.dart';

/// A pairing window, whole, as the core sends it after every change.
/// [PairingWaiting] and [PairingConfirming] are open; every other one is
/// how the window ended, and the last it sends.
sealed class PairingView {
  const PairingView();
}

/// Open, nothing redeemed yet: the [payload] to show (as text and QR),
/// this device's [deviceId] for the other side to compare, the [endpoint]
/// (`host:port`) the window answers on, and when the payload stops being
/// redeemable.
final class PairingWaiting extends PairingView {
  const PairingWaiting({
    required this.payload,
    required this.deviceId,
    required this.endpoint,
    required this.expiresAt,
  });

  final String payload;
  final String deviceId;
  final String endpoint;
  final DateTime expiresAt;
}

/// A device redeemed the payload and waits for the operator:
/// `CoreLink.confirmPairing` answers. [deviceId] is what the operator
/// compares with the id the other device shows; [name] is what it will be
/// listed under here.
final class PairingConfirming extends PairingView {
  const PairingConfirming({required this.deviceId, required this.name});

  final String deviceId;
  final String name;
}

/// Confirmed and recorded; grant it a root before it can reach one.
final class PairingEnrolled extends PairingView {
  const PairingEnrolled(this.device);

  final PairedDeviceInfo device;
}

final class PairingDeclined extends PairingView {
  const PairingDeclined(this.deviceId);

  final String deviceId;
}

/// Nobody answered before the token expired.
final class PairingUnconfirmed extends PairingView {
  const PairingUnconfirmed(this.deviceId);

  final String deviceId;
}

/// Confirmed, but the store refused it.
final class PairingNotStored extends PairingView {
  const PairingNotStored({required this.deviceId, required this.message});

  final String deviceId;
  final String message;
}

/// The token expired unredeemed; [window] is how long it was good for.
final class PairingExpired extends PairingView {
  const PairingExpired(this.window);

  final Duration window;
}

final class PairingCancelled extends PairingView {
  const PairingCancelled();
}

/// The listener itself failed.
final class PairingFailed extends PairingView {
  const PairingFailed(this.message);

  final String message;
}
