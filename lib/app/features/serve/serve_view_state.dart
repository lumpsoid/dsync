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
/// [sessions] is bounded by construction. `AgentListener`'s own
/// `SessionErrorHandler` doc warns that a head on a real network port must
/// keep this quiet rather than print one line per probe; a ring that cannot
/// grow past [maxSessions] satisfies that without a rate limiter's clock,
/// and nothing here is persisted.
class ServeViewState extends ChangeNotifier {
  /// How many session lines are kept. Enough to see a handful of refusals
  /// in a row while diagnosing a first phone-to-phone sync, few enough that
  /// a port being scanned costs a fixed amount of memory.
  static const int maxSessions = 20;

  ServeStatus _status = const ServeStopped();
  final List<String> _sessions = <String>[];

  /// Whether this device is answering, and where.
  ServeStatus get status => _status;

  /// What sessions have reported, newest first, at most [maxSessions] of
  /// them. Already rendered lines; the page draws them and decides nothing.
  List<String> get sessions => List.unmodifiable(_sessions);

  /// Moves the status. `ServeController` only.
  void recordStatus(ServeStatus status) {
    _status = status;
    notifyListeners();
  }

  /// Prepends one rendered session line, dropping the oldest once the ring
  /// is full. `ServeController` only.
  void recordSession(String line) {
    _sessions.insert(0, line);
    if (_sessions.length > maxSessions) _sessions.removeLast();
    notifyListeners();
  }

  /// Empties the ring — what a fresh bind starts from, so lines from the
  /// last time this page was open do not read as this one's.
  void clearSessions() {
    if (_sessions.isEmpty) return;
    _sessions.clear();
    notifyListeners();
  }
}
