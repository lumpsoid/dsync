import 'serve_view.dart';

/// Serving paired devices: the port bound, what to type on the other
/// device, and the session's [views] — the latest what to show — which
/// end with the one that says it stopped.
final class ServeSession {
  const ServeSession({
    required this.session,
    required this.port,
    required this.advertised,
    required this.deviceId,
    required this.views,
  });

  final int session;
  final int port;
  final String advertised;
  final String deviceId;
  final Stream<ServeView> views;
}
