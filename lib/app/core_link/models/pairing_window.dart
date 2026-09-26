import 'pairing_view.dart';

/// A pairing window the core opened: its id, which the answer and the
/// cancel name, and its [views] — the latest what to show — which end with
/// the one that says how it closed.
final class PairingWindow {
  const PairingWindow({required this.session, required this.views});

  final int session;
  final Stream<PairingView> views;
}
