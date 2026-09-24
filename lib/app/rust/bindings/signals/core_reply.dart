// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to the [`CoreRequest`] with the same `id`.
@immutable
class CoreReply {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _coreReplyStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<CoreReply>? latestRustSignal = null;

  const CoreReply({
    required this.id,
    required this.result,
  });

  static CoreReply deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreReply(
      id: deserializer.deserializeUint64(),
      result: ReplyResult.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CoreReply bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CoreReply.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 id;
  final ReplyResult result;

  CoreReply copyWith({
    Uint64? id,
    ReplyResult? result,
  }) {
    return CoreReply(
      id: id ?? this.id,
      result: result ?? this.result,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(id);
    result.serialize(serializer);
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

    return other is CoreReply
      && id == other.id
      && result == other.result;
  }

  @override
  int get hashCode => Object.hash(
        id,
        result,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'result: $result'
        ')';
      return true;
    }());

    return fullString ?? 'CoreReply';
  }
}

final _coreReplyStreamController =
    StreamController<RustSignalPack<CoreReply>>();
