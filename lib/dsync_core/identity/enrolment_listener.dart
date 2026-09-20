/// Accepts the one connection SPEC §4.4 lets a not-yet-paired peer make: the
/// enrolment exchange that turns a scanned or pasted [PairingPayload] into a
/// mutual pairing.
///
/// **Why this does not reuse `AgentListener.bindSecure`, and is not an
/// `AgentListener` at all.** [AgentListener.bindSecure]'s whole gate is
/// pinning a peer's certificate against `PairedDeviceStore` *before* the TLS
/// handshake completes: `requireClientCertificate: true`, plus every paired
/// device's certificate installed as a trust anchor, so BoringSSL itself
/// refuses a stranger before any code here sees the connection. An enrolling
/// peer is a stranger by construction — it has no pairing yet, so it has no
/// certificate `PairedDeviceStore` would ever install as a trust anchor —
/// and asking for one at the TLS layer would mean BoringSSL refusing the
/// exact connection this class exists to accept, the same constraint
/// [AgentListener.bindSecure]'s own doc comment already documents for the
/// paired case. So this binds the opposite gate: this host's own identity
/// presented as usual, `requireClientCertificate` left at its default
/// `false` — plain, server-authenticated TLS — and the peer authenticated
/// afterward, over the now-encrypted channel, by the token it presents
/// rather than by anything TLS itself checked. The QR's pinned certificate is
/// what authenticates *this* side to the peer — `onBadCertificate`'s
/// byte-exact pin, the same one `SocketChannel.connectSecure` uses for an
/// already-paired peer — and it is the whole reason this is not
/// trust-on-first-use: there is no prompt, no fingerprint dialog, no grace
/// period, because the certificate to pin against already travelled inside
/// the payload rather than being taken on faith from whoever answers first.
///
/// **Why this does not reopen what `d0e960` closed.** `d0e960`'s property is
/// "an unpaired peer never reaches `hello`, a `ReplicaSpec`, or any frame
/// parser." This file never imports `agent_server.dart`, `local_agent.dart`,
/// `replica_spec.dart`, `channel.dart` or `frame_codec.dart` — see
/// `enrolment_message.dart`'s own doc comment for why its wire shape is
/// deliberately not `Frame`'s. There is consequently no path from a socket
/// this listener accepts into anything that could reach a replica: the
/// entire surface an enrolling peer can touch is [EnrolmentRequest.decode]
/// and the token gate below, both pure data checks with nothing behind them
/// but `PairedDeviceStore.add`. A reviewer asking whether an endpoint for
/// unpaired peers reopens the hole `d0e960` closed can check it by import
/// graph alone, not by re-auditing this class's logic: nothing under
/// `dsync_core/agent/` or `dsync_core/protocol/` appears in this file's
/// imports, and nothing here calls back into either.
///
/// **The gate, concretely (SPEC §4.4).**
/// - **Off by default.** Nothing binds this listener implicitly — it exists
///   only for as long as whoever is running a pairing operation keeps it
///   bound, the same opt-in shape [AgentListener.bindUnix] and `bindSecure`
///   already have.
/// - **Time-bounded.** [tokenExpiresAt] is checked on every redemption
///   attempt, not once at bind time — an attempt arriving after it has
///   passed is refused the same as a wrong token.
/// - **Single-use, and the loser of the race sees a real refusal, not
///   silence.** [_redeemToken] is synchronous, with no `await` between
///   reading and setting the consumed flag, so Dart's own single-threaded
///   event loop — which only ever preempts at an `await` — cannot interleave
///   two connections inside it. Whichever accepted connection actually calls
///   it first wins; every later call — including a second presentation of
///   the *correct* token — returns `false`, which [_enrol] turns into
///   [EnrolmentRefused] rather than a connection that just looks like it
///   failed for no reason.
/// - **Bounded in time and in number, before any token is checked (task
///   224ffa).** A connection that has not presented a complete enrolment
///   message within [EnrolmentListener.defaultRequestDeadline] is destroyed,
///   and one accepted while
///   [EnrolmentListener.defaultMaxUnauthenticatedConnections] are already
///   waiting is destroyed at accept. Neither adds a parser or a demux in
///   front of the handshake — they are a timer and a counter, which is what
///   keeps the isolation argument above intact. Both start where this class
///   does, at an accepted [SecureSocket]: the TLS handshake itself happens
///   inside [SecureServerSocket] before anything here sees a connection, and
///   `dart:io` offers no hook to bound a peer that stalls inside it.
/// - **Unreachable once pairing has happened.** The token can succeed
///   exactly once, so even a listener left bound past its one legitimate use
///   accepts connections that can never complete one. The caller should
///   still [close] promptly once its pairing operation is done regardless —
///   both because an open port is attack surface even when nothing on it can
///   succeed, and because [close] is what actually satisfies "the endpoint
///   is closed after," rather than leaning on the gate alone to carry that
///   property.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsync/dsync_core/identity/device_id.dart';
import 'package:dsync/dsync_core/identity/enrolment_message.dart';
import 'package:dsync/dsync_core/identity/paired_device_store.dart';
import 'package:dsync/dsync_core/models/device_identity.dart';
import 'package:dsync/dsync_core/models/paired_device.dart';

/// A connection this listener could not turn into a completed enrolment, or
/// did turn into one that was refused — the mirror of `AgentListener`'s
/// `SessionErrorHandler`, defined fresh here rather than imported, since
/// nothing in this file otherwise depends on `agent_listener.dart` at all
/// (see the class doc comment on isolation).
typedef EnrolmentErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// A fresh, single-use enrolment token (SPEC §4.4).
///
/// **16 bytes, from `Random.secure()`.** `generateDeviceIdentity` seeds a
/// pointycastle Fortuna CSPRNG from `Random.secure()` because pointycastle's
/// key generator and signer need a `SecureRandom` object to drive; a token is
/// a flat run of random bytes with no algorithm to hand it to, so
/// `Random.secure()` — the platform CSPRNG `dart:math` already exposes —
/// serves the same underlying guarantee directly, with no Fortuna wrapping to
/// earn its keep. 128 bits is headroom, not a number chosen because anything
/// smaller would be guessable in this token's one meaningful use: the actual
/// gate is [EnrolmentListener]'s single-use, time-bounded redemption, which
/// already bounds an attacker who does not already hold the token to
/// (window length) ÷ (round trip time) guesses, not 2^128 of them.
Uint8List generateEnrolmentToken() =>
    Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));

/// The default enrolment token lifetime (SPEC §4.4: "the window is short").
///
/// Five minutes is enough for a human to open a QR on one device, walk to
/// the other, and either scan it or type the `dsync pair` command the same
/// text also pastes into — including the slower camera-less path SPEC §4.4
/// calls the primary one for a desktop-to-server pairing — and short enough
/// that a photograph taken over someone's shoulder is worthless a few
/// minutes later even before anyone has revoked anything.
const defaultEnrolmentTokenTtl = Duration(minutes: 5);

/// The refusal reason [EnrolmentListener._redeemToken] itself produces —
/// the only [EnrolmentRefused] reason reachable *before* the real token has
/// been redeemed, so it is the one a caller waiting out a pairing window
/// must ignore.
///
/// Exported because both things that show a payload and then wait —
/// `dsync pair show` and the Flutter head's pairing window — need to tell
/// "a stranger guessed and was turned away" (keep waiting) from "the token
/// was spent and the enrolment behind it still failed" (stop, and say why).
/// Neither re-spells the string.
const enrolmentTokenRejectedReason = 'Enrolment token rejected.';

class EnrolmentListener {
  /// How long an accepted connection has to present its enrolment message
  /// before its socket is destroyed (task 224ffa).
  ///
  /// The same shape, and the same injectability, as
  /// `IdleDeadlineChannel.defaultDeadline`: a named constant for the default
  /// and a parameter on [bind] so a test can drive a short one. There is
  /// nothing to tune — the message is one small write a real peer sends the
  /// instant its handshake completes, so ten seconds is generous for a slow
  /// link and still bounds a peer that connects and then says nothing, which
  /// would otherwise hold a socket for as long as this listener stays bound.
  /// It is the time half of the bound on this read; its size half is
  /// `maxEnrolmentMessageBytes`.
  static const defaultRequestDeadline = Duration(seconds: 10);

  /// How many accepted connections may be waiting to present a valid token
  /// at once before a further one is destroyed at accept (task 224ffa).
  ///
  /// The deadline above alone bounds concurrent unauthenticated sockets to
  /// (attacker's connect rate x deadline), which is barely a bound; this
  /// makes the bound independent of that rate. Sixteen is about two orders of
  /// magnitude of headroom for an endpoint whose legitimate traffic is one
  /// connection, once.
  static const defaultMaxUnauthenticatedConnections = 16;

  final SecureServerSocket _server;
  final PairedDeviceStore _pairedDeviceStore;
  final String _peerName;
  final Uint8List _token;
  final DateTime _tokenExpiresAt;
  final EnrolmentErrorHandler _onError;
  final Duration _requestDeadline;
  final int _maxUnauthenticatedConnections;
  late final StreamSubscription<void> _connections;

  final Completer<PairedDevice> _enrolled = Completer<PairedDevice>();

  bool _tokenConsumed = false;

  /// How many accepted connections are past accept and have not yet finished
  /// presenting a token — incremented at accept, decremented once the token
  /// has been judged or the connection has died (see [_handleConnection]).
  int _unauthenticatedConnections = 0;

  EnrolmentListener._(
    this._server,
    this._pairedDeviceStore,
    this._peerName,
    this._token,
    this._tokenExpiresAt,
    this._onError,
    this._requestDeadline,
    this._maxUnauthenticatedConnections,
  ) {
    _connections = _server.listen(_handleConnection, onError: _onError);
  }

  /// Binds a plain, server-authenticated TLS listener at [address]:[port],
  /// presenting [ownIdentity] and requesting no client certificate (see the
  /// class doc comment for why).
  ///
  /// [peerName] is what this host will call whatever device redeems the
  /// token — its own local handle for that peer (SPEC §4.4), the one
  /// `dsync pair grant <name> <path>` and `peer://<name>` address it by.
  /// It is taken here, from the side that shows the payload and therefore
  /// already knows what the operator means to call its peer, rather than
  /// proposed by the enrolling device: a name the far end chose is a name
  /// whoever won the enrolment race chose, and the operator's own device
  /// could then never pair under it. An empty [peerName] is a
  /// [FormatException] here, before a socket is bound, rather than a
  /// refusal the peer sees — it is this side's mistake, not the peer's.
  ///
  /// [token] and [tokenExpiresAt] are the gate a connecting peer has to
  /// satisfy to be recorded in [pairedDeviceStore]: generate [token] with
  /// [generateEnrolmentToken] and compute [tokenExpiresAt] from
  /// [defaultEnrolmentTokenTtl] unless there is a specific reason to pick a
  /// different window. The same [token] and [address] are what the caller
  /// bundles into the [PairingPayload] it hands to whatever renders the QR
  /// (or shows the pasteable text) — this method does not build that payload
  /// itself, since it has no opinion on which address a peer should be told
  /// to try, only on which token to accept.
  ///
  /// [requestDeadline] and [maxUnauthenticatedConnections] bound what a peer
  /// that has presented no token at all can cost this process (task 224ffa):
  /// how long one may hold a socket, and how many may hold one at once.
  /// Neither is a policy knob — see the constants they default to.
  static Future<EnrolmentListener> bind(
    InternetAddress address,
    int port, {
    required DeviceIdentity ownIdentity,
    required String peerName,
    required Uint8List token,
    required DateTime tokenExpiresAt,
    required PairedDeviceStore pairedDeviceStore,
    required EnrolmentErrorHandler onError,
    Duration requestDeadline = defaultRequestDeadline,
    int maxUnauthenticatedConnections = defaultMaxUnauthenticatedConnections,
  }) async {
    if (peerName.trim().isEmpty) {
      throw const FormatException('Empty device name');
    }
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(ownIdentity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(ownIdentity.privateKeyPem));
    // requireClientCertificate left at its default false: see the class doc
    // comment on why an enrolling peer cannot be asked for one at all.
    final server = await SecureServerSocket.bind(address, port, context);
    return EnrolmentListener._(
      server,
      pairedDeviceStore,
      peerName,
      token,
      tokenExpiresAt,
      onError,
      requestDeadline,
      maxUnauthenticatedConnections,
    );
  }

  /// The address this listener is bound to, `host:port` — read back off the
  /// bound socket rather than remembered from the argument, the same reason
  /// [AgentListener.address] is (relevant for an ephemeral port 0, which
  /// tests use).
  String get address => '${_server.address.address}:${_server.port}';

  /// Completes with the device recorded by the one enrolment this listener
  /// can ever accept.
  ///
  /// Exactly one, by construction rather than by convention: the token is
  /// burned on its first successful redemption, so no second connection can
  /// reach [_pairedDeviceStore] however long this stays bound. That is what
  /// lets this be a [Future] rather than a stream of events.
  ///
  /// **It completes on success and never otherwise** — a refused connection
  /// goes to [EnrolmentErrorHandler], where a caller that cares can see it
  /// without having its wait ended by a stranger's failed probe, which is
  /// the distinction a one-shot pairing window needs. A caller therefore
  /// races this against its own reason to stop — a signal, a deadline, the
  /// token's own expiry — rather than awaiting it alone. `dsync pair show`
  /// is the worked example.
  Future<PairedDevice> get enrolled => _enrolled.future;

  /// Stops accepting, and releases the socket. A connection already
  /// mid-exchange is not waited for: each one is a single request and a
  /// single reply, not a session, so there is nothing worth blocking a
  /// caller's shutdown on.
  Future<void> close() async {
    await _server.close();
    await _connections.cancel();
  }

  /// Reads one connection's enrolment message, judges it, and answers — with
  /// both halves of task 224ffa's bound around the part of that which happens
  /// before any token has been checked.
  ///
  /// The cap is checked at accept, before the read is even started, so it
  /// bounds sockets rather than only the work done on them; the deadline
  /// covers the read and the judgement, and a connection that misses it is
  /// destroyed, since nothing else would ever close a socket whose peer is
  /// deliberately silent. Both are released before the reply is written: by
  /// then the token has been judged, so the write is no longer a cost an
  /// unauthenticated peer can impose at will.
  Future<void> _handleConnection(SecureSocket socket) async {
    if (_unauthenticatedConnections >= _maxUnauthenticatedConnections) {
      _onError(
        const TooManyEnrolmentConnectionsException(),
        StackTrace.current,
      );
      socket.destroy();
      return;
    }

    _unauthenticatedConnections++;
    final EnrolmentReply reply;
    try {
      final requestBytes = await readEnrolmentMessage(socket).timeout(
        _requestDeadline,
        onTimeout: () => throw const EnrolmentDeadlineExceededException(),
      );
      reply = await _enrol(EnrolmentRequest.decode(requestBytes), socket);
    } catch (error, stackTrace) {
      _onError(error, stackTrace);
      socket.destroy();
      return;
    } finally {
      _unauthenticatedConnections--;
    }

    try {
      socket.add(reply.encode());
      await socket.flush();
    } finally {
      await socket.close();
      socket.destroy();
    }
    if (reply case EnrolmentRefused(:final reason)) {
      _onError(EnrolmentRefusedException(reason), StackTrace.current);
    }
  }

  /// Validates and, on success, records [request] — the whole of what an
  /// enrolling peer can make this listener do.
  Future<EnrolmentReply> _enrol(
    EnrolmentRequest request,
    SecureSocket socket,
  ) async {
    if (!_redeemToken(request.token)) {
      return const EnrolmentRefused(enrolmentTokenRejectedReason);
    }

    try {
      // Validated for its own sake, not only for the side effect below:
      // `PairedDeviceStore.add` computes `PairedDevice.deviceId` internally
      // for its own collision check, and a malformed certificate would
      // otherwise surface there as an uncaught parse failure rather than a
      // refusal — the same defense `AgentListener._resolvePeer` already
      // applies to a peer's certificate, for the same underlying reason.
      deviceIdFromCertificateDer(certificateDerFromPem(request.certificatePem));
    } catch (_) {
      return const EnrolmentRefused('Malformed certificate.');
    }

    final device = PairedDevice(
      certificatePem: request.certificatePem,
      // This side's own choice, taken at `bind` and never influenced by
      // anything the peer sent — see [EnrolmentRequest]'s doc comment for
      // what a peer-chosen name let a winner of the enrolment race do.
      // Non-empty by construction: `bind` refuses an empty one, so the
      // `PairedDevice` constructor's own rule cannot fire here.
      name: _peerName,
      // Empty by construction (SPEC §4.4): pairing a device's identity and
      // authorizing it for a replica are always two steps, and this is
      // only the first. A freshly enrolled device is trusted and reaches
      // nothing until roots are granted separately — see
      // `PairedDevice.agreedReplicaRoots`'s own doc comment.
      agreedReplicaRoots: const {},
      pairedAt: DateTime.now(),
      // The host actually observed on this socket, not anything the peer
      // claimed about itself — the same reason `AgentListener` resolves a
      // peer from `socket.peerCertificate` rather than a self-reported
      // identity.
      //
      // The *port* is deliberately the default rather than
      // `socket.remotePort`, which is this connection's ephemeral source
      // port — a number the peer's kernel picked for one outbound
      // connection and will not be listening on afterwards. Recording it
      // would put an address in the store that is guaranteed not to work,
      // which is worse than a guess: SPEC §4.4's cache exists to be dialed
      // later, and this side has never dialed this peer at all. It learned
      // a host, so it records the host and the port a listener would use
      // by default; the first connection this side actually makes will
      // overwrite both through `recordConnection`.
      lastKnownAddress: PeerAddress(host: socket.remoteAddress.address),
    );

    try {
      await _pairedDeviceStore.add(device);
    } on PairedDeviceCollisionException catch (e) {
      return EnrolmentRefused(e.toString());
    }

    // After the store write, not before: [enrolled] promises a device that is
    // actually recorded, so a caller woken by it can read the store back and
    // find it there.
    _enrolled.complete(device);
    return const EnrolmentAccepted();
  }

  /// Attempts to redeem [presented] against this listener's token — the
  /// atomic step SPEC §4.4 calls a "successful redemption," and the only
  /// thing that is single-use. See the class doc comment for why this is
  /// safe against two connections racing to redeem the same token.
  ///
  /// Deliberately decoupled from whatever happens after: a token that
  /// matched but whose connection then sent a malformed certificate, or a
  /// name that collides with an existing pairing, still burns the token. The
  /// alternative — only burning it once the whole enrolment has actually
  /// succeeded — reopens exactly the race this exists to close, since two
  /// connections that both hold the one real token could then both pass this
  /// check, and only luck would decide which one's later, unrelated failure
  /// hands the token back to the other. A legitimate retry after such a
  /// failure needs a fresh token, the same as a legitimate retry after any
  /// other single-use credential is spent.
  bool _redeemToken(Uint8List presented) {
    final expired = !DateTime.now().isBefore(_tokenExpiresAt);
    final valid =
        !_tokenConsumed && !expired && _constantTimeEquals(presented, _token);
    if (valid) _tokenConsumed = true;
    return valid;
  }
}

/// Reported to [EnrolmentErrorHandler] when an accepted connection did not
/// present a complete enrolment message within
/// [EnrolmentListener.defaultRequestDeadline] (task 224ffa) — a peer that
/// completed the TLS handshake and then said nothing, or said only part of a
/// message.
///
/// Its socket is destroyed: nothing else would ever close a connection whose
/// peer is deliberately silent, and this read happens before any token has
/// been checked, so the peer is anybody at all.
class EnrolmentDeadlineExceededException implements Exception {
  const EnrolmentDeadlineExceededException();

  @override
  String toString() =>
      'Destroyed a connection that did not present an enrolment message '
      'within the request deadline.';
}

/// Reported to [EnrolmentErrorHandler] when a connection is accepted while
/// the listener's cap on connections that have not yet presented a token is
/// already reached (task 224ffa).
///
/// The deadline above bounds how long one such connection may live; this
/// bounds how many may live at once, which is what makes the bound
/// independent of how fast an attacker can open connections.
class TooManyEnrolmentConnectionsException implements Exception {
  const TooManyEnrolmentConnectionsException();

  @override
  String toString() =>
      'Destroyed a connection: too many connections are already waiting to '
      'present an enrolment token.';
}

/// Compares [a] and [b] without stopping at the first differing byte, so how
/// long a wrong guess took to reject cannot leak how many leading bytes it
/// got right.
///
/// Overkill against the actual threat here — a short-lived, single-use,
/// in-memory token an attacker who does not already hold it gets, at best,
/// one meaningful guess against per pairing window — but the comparison
/// itself is three lines, and the alternative is a reader having to work out
/// for themselves that an early-exit compare would still have been fine.
bool _constantTimeEquals(Uint8List a, Uint8List b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
