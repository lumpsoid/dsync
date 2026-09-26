import '../rust/bindings/bindings.dart' as wire;

/// The head's one seam with the Rust hub (native/hub): requests go out,
/// and replies and session signals come back, all as the classes
/// `rinf gen` writes from native/hub/src/signals.rs.
///
/// An interface because the real channel cannot run where the head's
/// tests run: `flutter test` cannot load the native library (SPEC.md §14).
/// The app runs on [RinfCoreChannel]; a test hands [CoreLink] a fake that
/// answers with generated reply values and feeds generated session
/// signals, so everything above this seam — correlation, decoding, the
/// controllers — is the code the app runs.
abstract interface class CoreChannel {
  /// Hands [request] to the hub. Answered by one [replies] value with the
  /// same id.
  void send(wire.CoreRequest request);

  Stream<wire.CoreReply> get replies;

  Stream<wire.RunSnapshot> get runSnapshots;

  Stream<wire.ServeSnapshot> get serveSnapshots;

  Stream<wire.EnrolmentUpdate> get enrolmentUpdates;
}

/// The [CoreChannel] over rinf's signals. Needs `initializeRust` to have
/// run.
final class RinfCoreChannel implements CoreChannel {
  const RinfCoreChannel();

  @override
  void send(wire.CoreRequest request) => request.sendSignalToRust();

  @override
  Stream<wire.CoreReply> get replies =>
      wire.CoreReply.rustSignalStream.map((pack) => pack.message);

  @override
  Stream<wire.RunSnapshot> get runSnapshots =>
      wire.RunSnapshot.rustSignalStream.map((pack) => pack.message);

  @override
  Stream<wire.ServeSnapshot> get serveSnapshots =>
      wire.ServeSnapshot.rustSignalStream.map((pack) => pack.message);

  @override
  Stream<wire.EnrolmentUpdate> get enrolmentUpdates =>
      wire.EnrolmentUpdate.rustSignalStream.map((pack) => pack.message);
}
