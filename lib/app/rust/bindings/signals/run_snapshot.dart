// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The run in `session`, whole, as it now stands.
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
  });

  static RunSnapshot deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunSnapshot(
      session: deserializer.deserializeUint64(),
      view: RunView.deserialize(deserializer),
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

  RunSnapshot copyWith({
    Uint64? session,
    RunView? view,
  }) {
    return RunSnapshot(
      session: session ?? this.session,
      view: view ?? this.view,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(session);
    view.serialize(serializer);
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
      && view == other.view;
  }

  @override
  int get hashCode => Object.hash(
        session,
        view,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'session: $session, '
        'view: $view'
        ')';
      return true;
    }());

    return fullString ?? 'RunSnapshot';
  }
}

final _runSnapshotStreamController =
    StreamController<RustSignalPack<RunSnapshot>>();
