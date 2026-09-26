/// Whether serving answers, as the core says.
sealed class ServePhase {
  const ServePhase();
}

/// Answering: [advertised] is what to type on the other device.
final class ServePhaseListening extends ServePhase {
  const ServePhaseListening(this.advertised);

  final String advertised;
}

/// Stopped by the head.
final class ServePhaseStopped extends ServePhase {
  const ServePhaseStopped();
}

/// The listener failed on its own.
final class ServePhaseFailed extends ServePhase {
  const ServePhaseFailed(this.message);

  final String message;
}
