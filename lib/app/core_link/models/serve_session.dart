import 'serve_update.dart';

/// Serving paired devices: the port bound, what to type on the other
/// device, and each connection's story in [updates], which ends with a
/// [ServeStopped].
final class ServeSession {
  const ServeSession({
    required this.session,
    required this.port,
    required this.advertised,
    required this.deviceId,
    required this.updates,
  });

  final int session;
  final int port;
  final String advertised;
  final String deviceId;
  final Stream<ServeUpdate> updates;
}
