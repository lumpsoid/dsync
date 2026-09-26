import 'serve_line.dart';
import 'serve_phase.dart';

/// Serving, whole, as the core sends it after every change: whether it
/// answers, and what connections reported, newest first, a bounded few.
final class ServeView {
  const ServeView({required this.phase, required this.lines});

  final ServePhase phase;
  final List<ServeLine> lines;
}
