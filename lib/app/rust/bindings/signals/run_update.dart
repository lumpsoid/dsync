// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One step of the run in `session`.
@immutable
class RunUpdate {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _runUpdateStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<RunUpdate>? latestRustSignal = null;

  const RunUpdate({
    required this.session,
    required this.update,
  });

  static RunUpdate deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdate(
      session: deserializer.deserializeUint64(),
      update: RunUpdateBody.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RunUpdate bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunUpdate.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 session;
  final RunUpdateBody update;

  RunUpdate copyWith({
    Uint64? session,
    RunUpdateBody? update,
  }) {
    return RunUpdate(
      session: session ?? this.session,
      update: update ?? this.update,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(session);
    update.serialize(serializer);
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

    return other is RunUpdate
      && session == other.session
      && update == other.update;
  }

  @override
  int get hashCode => Object.hash(
        session,
        update,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'session: $session, '
        'update: $update'
        ')';
      return true;
    }());

    return fullString ?? 'RunUpdate';
  }
}

final _runUpdateStreamController =
    StreamController<RustSignalPack<RunUpdate>>();
