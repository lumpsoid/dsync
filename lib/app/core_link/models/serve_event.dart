/// One connection event while serving paired devices.
sealed class ServeEvent {
  const ServeEvent();
}

/// A connection turned away before a session began.
final class ServeRefused extends ServeEvent {
  const ServeRefused({required this.from, required this.message});

  final String from;
  final String message;
}

final class ServeSessionStarted extends ServeEvent {
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
final class ServeServing extends ServeEvent {
  const ServeServing(this.root);

  final String root;
}

final class ServeSessionEnded extends ServeEvent {
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
