// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Rust is listening; [device_id] is the id a pushing peer pins.
@immutable
class ServeReady {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _serveReadyStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<ServeReady>? latestRustSignal = null;

  const ServeReady({
    required this.port,
    required this.deviceId,
  });

  static ServeReady deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeReady(
      port: deserializer.deserializeUint16(),
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ServeReady bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeReady.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int port;
  final String deviceId;

  ServeReady copyWith({
    int? port,
    String? deviceId,
  }) {
    return ServeReady(
      port: port ?? this.port,
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint16(port);
    serializer.serializeString(deviceId);
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

    return other is ServeReady
      && port == other.port
      && deviceId == other.deviceId;
  }

  @override
  int get hashCode => Object.hash(
        port,
        deviceId,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'port: $port, '
        'deviceId: $deviceId'
        ')';
      return true;
    }());

    return fullString ?? 'ServeReady';
  }
}

final _serveReadyStreamController =
    StreamController<RustSignalPack<ServeReady>>();
