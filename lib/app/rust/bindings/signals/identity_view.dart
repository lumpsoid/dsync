// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// This device: its id, the name its certificate carries, the window and
/// SPEC §4.4's expiry warning when due.
@immutable
class IdentityView {
  const IdentityView({
    required this.deviceId,
    this.commonName,
    required this.notBeforeMs,
    required this.notAfterMs,
    this.expiryNote,
  });

  static IdentityView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = IdentityView(
      deviceId: deserializer.deserializeString(),
      commonName: TraitHelpers.deserializeOptionStr(deserializer),
      notBeforeMs: deserializer.deserializeInt64(),
      notAfterMs: deserializer.deserializeInt64(),
      expiryNote: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static IdentityView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = IdentityView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String deviceId;
  final String? commonName;
  final int notBeforeMs;
  final int notAfterMs;
  final String? expiryNote;

  IdentityView copyWith({
    String? deviceId,
    String? Function()? commonName,
    int? notBeforeMs,
    int? notAfterMs,
    String? Function()? expiryNote,
  }) {
    return IdentityView(
      deviceId: deviceId ?? this.deviceId,
      commonName: commonName == null ? this.commonName : commonName(),
      notBeforeMs: notBeforeMs ?? this.notBeforeMs,
      notAfterMs: notAfterMs ?? this.notAfterMs,
      expiryNote: expiryNote == null ? this.expiryNote : expiryNote(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(deviceId);
    TraitHelpers.serializeOptionStr(commonName, serializer);
    serializer.serializeInt64(notBeforeMs);
    serializer.serializeInt64(notAfterMs);
    TraitHelpers.serializeOptionStr(expiryNote, serializer);
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

    return other is IdentityView
      && deviceId == other.deviceId
      && commonName == other.commonName
      && notBeforeMs == other.notBeforeMs
      && notAfterMs == other.notAfterMs
      && expiryNote == other.expiryNote;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        commonName,
        notBeforeMs,
        notAfterMs,
        expiryNote,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId, '
        'commonName: $commonName, '
        'notBeforeMs: $notBeforeMs, '
        'notAfterMs: $notAfterMs, '
        'expiryNote: $expiryNote'
        ')';
      return true;
    }());

    return fullString ?? 'IdentityView';
  }
}
