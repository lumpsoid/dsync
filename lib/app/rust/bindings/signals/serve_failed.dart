// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Serving ended without a finished transfer: bind, handshake, I/O, or a
/// refused peer. A [StopServe] ends it without this.
@immutable
class ServeFailed {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _serveFailedStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<ServeFailed>? latestRustSignal = null;

  const ServeFailed({
    required this.message,
  });

  static ServeFailed deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeFailed(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ServeFailed bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeFailed.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String message;

  ServeFailed copyWith({
    String? message,
  }) {
    return ServeFailed(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(message);
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

    return other is ServeFailed
      && message == other.message;
  }

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'ServeFailed';
  }
}

final _serveFailedStreamController =
    StreamController<RustSignalPack<ServeFailed>>();
