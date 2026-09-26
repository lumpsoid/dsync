// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The pairing window `session`, whole, as it now stands.
@immutable
class PairingSnapshot {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _pairingSnapshotStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<PairingSnapshot>? latestRustSignal = null;

  const PairingSnapshot({
    required this.session,
    required this.view,
  });

  static PairingSnapshot deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingSnapshot(
      session: deserializer.deserializeUint64(),
      view: PairingView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static PairingSnapshot bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PairingSnapshot.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 session;
  final PairingView view;

  PairingSnapshot copyWith({
    Uint64? session,
    PairingView? view,
  }) {
    return PairingSnapshot(
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

    return other is PairingSnapshot
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

    return fullString ?? 'PairingSnapshot';
  }
}

final _pairingSnapshotStreamController =
    StreamController<RustSignalPack<PairingSnapshot>>();
