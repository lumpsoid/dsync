// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// An open pairing window: the payload to show (as text and QR), this
/// device's id to compare, and where the window answers.
@immutable
class PairingShownView {
  const PairingShownView({
    required this.payload,
    required this.deviceId,
    required this.endpoint,
    required this.expiresInSeconds,
  });

  static PairingShownView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingShownView(
      payload: deserializer.deserializeString(),
      deviceId: deserializer.deserializeString(),
      endpoint: deserializer.deserializeString(),
      expiresInSeconds: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static PairingShownView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PairingShownView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String payload;
  final String deviceId;
  final String endpoint;
  final Uint64 expiresInSeconds;

  PairingShownView copyWith({
    String? payload,
    String? deviceId,
    String? endpoint,
    Uint64? expiresInSeconds,
  }) {
    return PairingShownView(
      payload: payload ?? this.payload,
      deviceId: deviceId ?? this.deviceId,
      endpoint: endpoint ?? this.endpoint,
      expiresInSeconds: expiresInSeconds ?? this.expiresInSeconds,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(payload);
    serializer.serializeString(deviceId);
    serializer.serializeString(endpoint);
    serializer.serializeUint64(expiresInSeconds);
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

    return other is PairingShownView
      && payload == other.payload
      && deviceId == other.deviceId
      && endpoint == other.endpoint
      && expiresInSeconds == other.expiresInSeconds;
  }

  @override
  int get hashCode => Object.hash(
        payload,
        deviceId,
        endpoint,
        expiresInSeconds,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'payload: $payload, '
        'deviceId: $deviceId, '
        'endpoint: $endpoint, '
        'expiresInSeconds: $expiresInSeconds'
        ')';
      return true;
    }());

    return fullString ?? 'PairingShownView';
  }
}
