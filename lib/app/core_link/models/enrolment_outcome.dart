import 'paired_device_info.dart';

/// How a pairing window ended.
sealed class EnrolmentOutcome {
  const EnrolmentOutcome();
}

/// Confirmed and recorded; grant it a root before it can reach one.
final class Enrolled extends EnrolmentOutcome {
  const Enrolled(this.device);

  final PairedDeviceInfo device;
}

final class EnrolmentDeclined extends EnrolmentOutcome {
  const EnrolmentDeclined(this.deviceId);

  final String deviceId;
}

/// Nobody answered before the token expired.
final class EnrolmentUnconfirmed extends EnrolmentOutcome {
  const EnrolmentUnconfirmed(this.deviceId);

  final String deviceId;
}

/// Confirmed, but the store refused it.
final class EnrolmentNotStored extends EnrolmentOutcome {
  const EnrolmentNotStored({required this.deviceId, required this.message});

  final String deviceId;
  final String message;
}

/// The token expired unredeemed.
final class EnrolmentExpired extends EnrolmentOutcome {
  const EnrolmentExpired();
}

final class EnrolmentCancelled extends EnrolmentOutcome {
  const EnrolmentCancelled();
}

/// The listener itself failed.
final class EnrolmentFailed extends EnrolmentOutcome {
  const EnrolmentFailed(this.message);

  final String message;
}
