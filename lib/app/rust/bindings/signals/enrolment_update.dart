// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The pairing window `session`.
@immutable
class EnrolmentUpdate {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _enrolmentUpdateStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<EnrolmentUpdate>? latestRustSignal = null;

  const EnrolmentUpdate({
    required this.session,
    required this.update,
  });

  static EnrolmentUpdate deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentUpdate(
      session: deserializer.deserializeUint64(),
      update: EnrolmentUpdateBody.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static EnrolmentUpdate bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EnrolmentUpdate.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 session;
  final EnrolmentUpdateBody update;

  EnrolmentUpdate copyWith({
    Uint64? session,
    EnrolmentUpdateBody? update,
  }) {
    return EnrolmentUpdate(
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

    return other is EnrolmentUpdate
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

    return fullString ?? 'EnrolmentUpdate';
  }
}

final _enrolmentUpdateStreamController =
    StreamController<RustSignalPack<EnrolmentUpdate>>();
