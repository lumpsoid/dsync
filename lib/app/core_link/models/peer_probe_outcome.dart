/// Whether a paired device answers and admits this host.
sealed class PeerProbeOutcome {
  const PeerProbeOutcome();
}

final class PeerReachable extends PeerProbeOutcome {
  const PeerReachable(this.address);

  final String address;
}

/// Nothing answered: only the address is in doubt.
final class PeerUnreachable extends PeerProbeOutcome {
  const PeerUnreachable(this.message);

  final String message;
}

/// Something answered, and the pairing or a certificate is the problem.
final class PeerRefused extends PeerProbeOutcome {
  const PeerRefused(this.message);

  final String message;
}
