// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The serving session `session`, whole, as it now stands.
@immutable
class ServeSnapshot {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _serveSnapshotStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<ServeSnapshot>? latestRustSignal = null;

  const ServeSnapshot({
    required this.session,
    required this.view,
  });

  static ServeSnapshot deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeSnapshot(
      session: deserializer.deserializeUint64(),
      view: ServeView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ServeSnapshot bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeSnapshot.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 session;
  final ServeView view;

  ServeSnapshot copyWith({
    Uint64? session,
    ServeView? view,
  }) {
    return ServeSnapshot(
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

    return other is ServeSnapshot
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

    return fullString ?? 'ServeSnapshot';
  }
}

final _serveSnapshotStreamController =
    StreamController<RustSignalPack<ServeSnapshot>>();
