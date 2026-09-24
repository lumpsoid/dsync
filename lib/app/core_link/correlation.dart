import 'dart:async';

/// Request/response over one-way signals: each request takes a fresh id,
/// and the reply carrying that id completes the future waiting on it.
///
/// Replies may arrive in any order; each resolves its own request. A reply
/// for an id nobody is waiting on — a request from before a hot restart, or
/// one answered twice — is dropped.
final class Correlator<R> {
  int _next = 0;
  final Map<int, Completer<R>> _waiting = {};

  /// A fresh id and the future its reply completes. The id is also the
  /// session id of a command that starts a session, so a caller can open
  /// the session's stream (with [SessionStreams.open]) before sending.
  ({int id, Future<R> reply}) open() {
    final id = ++_next;
    final completer = Completer<R>();
    _waiting[id] = completer;
    return (id: id, reply: completer.future);
  }

  /// Completes request [id] with [reply]; a no-op for an unknown id.
  void complete(int id, R reply) => _waiting.remove(id)?.complete(reply);

  /// Fails request [id] (the send itself failed); a no-op for an unknown
  /// id.
  void fail(int id, Object error) => _waiting.remove(id)?.completeError(error);

  /// How many requests still wait for a reply.
  int get pending => _waiting.length;
}

/// The streams of live sessions, by session id: updates for a session go
/// to its stream, the terminal one closes it, and an update for a session
/// nobody opened (or that already ended) is dropped.
///
/// A session's stream buffers until it is listened to, so updates that
/// arrive before the caller subscribes are not lost.
final class SessionStreams<U> {
  SessionStreams({required this.isTerminal});

  /// Whether [update] is the last one its session sends.
  final bool Function(U update) isTerminal;

  final Map<int, StreamController<U>> _open = {};

  /// The stream for session [id]. Open it before sending the command that
  /// starts the session.
  Stream<U> open(int id) {
    final controller = _open[id] ??= StreamController<U>();
    return controller.stream;
  }

  /// Delivers [update] to session [id], closing its stream on the terminal
  /// update.
  void deliver(int id, U update) {
    final controller = _open[id];
    if (controller == null) return;
    controller.add(update);
    if (isTerminal(update)) {
      _open.remove(id);
      controller.close();
    }
  }

  /// Closes session [id]'s stream with [error]: the command that would
  /// have started it failed, so no update will come.
  void abandon(int id, Object error) {
    final controller = _open.remove(id);
    if (controller == null) return;
    controller.addError(error);
    controller.close();
  }

  /// Sessions whose streams are still open.
  Iterable<int> get live => _open.keys;
}
