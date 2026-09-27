// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The run in `session` as it now stands, its plan as an update to the
/// one the snapshot before carried (see [`RunView`]). `last`: the session
/// is over - finished, stopped, or the page left - and sends nothing more.
@immutable
class RunSnapshot {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _runSnapshotStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<RunSnapshot>? latestRustSignal = null;

  const RunSnapshot({
    required this.session,
    required this.view,
    required this.last,
  });

  static RunSnapshot deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunSnapshot(
      session: deserializer.deserializeUint64(),
      view: RunView.deserialize(deserializer),
      last: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RunSnapshot bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunSnapshot.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 session;
  final RunView view;
  final bool last;

  RunSnapshot copyWith({
    Uint64? session,
    RunView? view,
    bool? last,
  }) {
    return RunSnapshot(
      session: session ?? this.session,
      view: view ?? this.view,
      last: last ?? this.last,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(session);
    view.serialize(serializer);
    serializer.serializeBool(last);
    serializer.decreaseContainerDepth();
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunSnapshot
      && session == other.session
      && view == other.view
      && last == other.last;
  }

  @override
  int get hashCode => Object.hash(
        session,
        view,
        last,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'session: $session, '
        'view: $view, '
        'last: $last'
        ')';
      return true;
    }());

    return fullString ?? 'RunSnapshot';
  }
}

final _runSnapshotStreamController =
    StreamController<RustSignalPack<RunSnapshot>>();
