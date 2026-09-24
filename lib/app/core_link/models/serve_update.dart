/// One step of serving paired devices.
sealed class ServeUpdate {
  const ServeUpdate();
}

final class ServeRefused extends ServeUpdate {
  const ServeRefused({required this.from, required this.message});

  final String from;
  final String message;
}

final class ServeSessionStarted extends ServeUpdate {
  const ServeSessionStarted({
    required this.from,
    required this.deviceId,
    required this.name,
  });

  final String from;
  final String deviceId;
  final String name;
}

/// A session opened the replica at [root] (expanded).
final class ServeServing extends ServeUpdate {
  const ServeServing(this.root);

  final String root;
}

final class ServeSessionEnded extends ServeUpdate {
  const ServeSessionEnded({
    required this.from,
    required this.deviceId,
    required this.name,
    required this.failure,
  });

  final String from;
  final String deviceId;
  final String name;
  final String? failure;
}

/// The last update: stopped, or the listener failed ([failure]).
final class ServeStopped extends ServeUpdate {
  const ServeStopped(this.failure);

  final String? failure;
}
