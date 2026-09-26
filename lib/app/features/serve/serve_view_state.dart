import 'package:flutter/foundation.dart';

/// Whether this device is answering paired devices right now, and where.
///
/// A sealed hierarchy rather than a bool beside a nullable address and a
/// nullable error, for the reason `SharedFoldersViewState` gives: the three
/// cannot drift apart, and the page switches over every case.
sealed class ServeStatus {
  const ServeStatus();
}

/// Not answering. The state a Serve page starts in and returns to, and the
/// state every device is in until someone opens this page.
final class ServeStopped extends ServeStatus {
  const ServeStopped();
}

/// Binding: the identity is being loaded and the socket opened. Short, and
/// shown rather than skipped because a bind that fails fails from here.
final class ServeStarting extends ServeStatus {
  const ServeStarting();
}

/// Answering at [address] — already rendered as `host:port`, the text a
/// user types into the other device's address field (SPEC §4.4's manual
/// re-entry, which is how a peer reaches this device when no pairing
/// cached the right host).
final class ServeListening extends ServeStatus {
  const ServeListening(this.address);

  final String address;
}

/// The socket could not be bound. [message] names the port and what holds
/// it — the same two causes `AgentBindException` names for the CLI.
final class ServeFailed extends ServeStatus {
  const ServeFailed(this.message);

  final String message;
}

/// The rendered values local to the Serve page (SPEC §4.4, §13).
///
/// Deliberately not the shared folders: they are an inversion of
/// `AppState.devices`, computed on read by `SharedFolderRow.renderAll`, and
/// a copy here would be a second thing to keep in step with every grant
/// made anywhere else in the app — the same reasoning
/// `SharedFoldersViewState` records.
///
/// [sessions] is the core's: the few lines its serving session keeps,
/// newest first, rendered. `AgentListener`'s own `SessionErrorHandler` doc
/// warns that a head on a real network port must keep this quiet rather
/// than print one line per probe, and the core's bound is what does.
class ServeViewState extends ChangeNotifier {
  ServeStatus _status = const ServeStopped();
  List<String> _sessions = const [];

  /// Whether this device is answering, and where.
  ServeStatus get status => _status;

  /// What sessions have reported, newest first. Already rendered lines;
  /// the page draws them and decides nothing.
  List<String> get sessions => _sessions;

  /// Moves the status. `ServeController` only.
  void recordStatus(ServeStatus status) {
    _status = status;
    notifyListeners();
  }

  /// Renders the core's latest view of serving: [status], and [sessions]
  /// newest first. `ServeController` only.
  void show({required ServeStatus status, required List<String> sessions}) {
    _status = status;
    _sessions = List.unmodifiable(sessions);
    notifyListeners();
  }
}
