// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Dart asks the core for one thing. Answered by one [`CoreReply`] with
/// the same `id`.
@immutable
class CoreRequest {
  const CoreRequest({
    required this.id,
    required this.command,
  });

  static CoreRequest deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreRequest(
      id: deserializer.deserializeUint64(),
      command: CoreCommand.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CoreRequest bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CoreRequest.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 id;
  final CoreCommand command;

  CoreRequest copyWith({
    Uint64? id,
    CoreCommand? command,
  }) {
    return CoreRequest(
      id: id ?? this.id,
      command: command ?? this.command,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(id);
    command.serialize(serializer);
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

    return other is CoreRequest
      && id == other.id
      && command == other.command;
  }

  @override
  int get hashCode => Object.hash(
        id,
        command,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'command: $command'
        ')';
      return true;
    }());

    return fullString ?? 'CoreRequest';
  }
}

extension CoreRequestDartSignalExt on CoreRequest {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_core_request',
      messageBytes,
      binary,
    );
  }
}
