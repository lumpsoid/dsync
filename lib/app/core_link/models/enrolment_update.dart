import 'enrolment_outcome.dart';

/// One step of a pairing window's story.
sealed class EnrolmentUpdate {
  const EnrolmentUpdate();
}

/// A connection turned away before it redeemed the token.
final class EnrolmentRefused extends EnrolmentUpdate {
  const EnrolmentRefused({required this.from, required this.message});

  final String from;
  final String message;
}

/// A device redeemed the payload and waits for the operator: answer with
/// `CoreLink.confirmPairing`. [deviceId] is what the operator compares
/// with the id the other device shows.
final class EnrolmentAwaiting extends EnrolmentUpdate {
  const EnrolmentAwaiting({
    required this.from,
    required this.deviceId,
    required this.name,
  });

  final String from;
  final String deviceId;
  final String name;
}

/// The window closed; the last update of its stream.
final class EnrolmentEnded extends EnrolmentUpdate {
  const EnrolmentEnded(this.outcome);

  final EnrolmentOutcome outcome;
}
