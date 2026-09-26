import 'serve_event.dart';

/// One connection [event], [at] the time the core saw it.
final class ServeLine {
  const ServeLine({required this.at, required this.event});

  final DateTime at;
  final ServeEvent event;
}
