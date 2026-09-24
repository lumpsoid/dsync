// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Serving: the port bound and what to type on the other device.
@immutable
class ServeStartedView {
  const ServeStartedView({
    required this.port,
    required this.advertised,
    required this.deviceId,
  });

  static ServeStartedView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeStartedView(
      port: deserializer.deserializeUint16(),
      advertised: deserializer.deserializeString(),
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ServeStartedView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeStartedView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int port;
  final String advertised;
  final String deviceId;

  ServeStartedView copyWith({
    int? port,
    String? advertised,
    String? deviceId,
  }) {
    return ServeStartedView(
      port: port ?? this.port,
      advertised: advertised ?? this.advertised,
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint16(port);
    serializer.serializeString(advertised);
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

    return other is ServeStartedView
      && port == other.port
      && advertised == other.advertised
      && deviceId == other.deviceId;
  }

  @override
  int get hashCode => Object.hash(
        port,
        advertised,
        deviceId,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'port: $port, '
        'advertised: $advertised, '
        'deviceId: $deviceId'
        ')';
      return true;
    }());

    return fullString ?? 'ServeStartedView';
  }
}
