// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A paired device as its row shows it.
@immutable
class DeviceView {
  const DeviceView({
    required this.deviceId,
    required this.name,
    this.commonName,
    required this.grantedRoots,
    required this.address,
    required this.pairedAtMs,
    this.verifiedAtMs,
    required this.notBeforeMs,
    required this.notAfterMs,
    this.expiryNote,
  });

  static DeviceView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = DeviceView(
      deviceId: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
      commonName: TraitHelpers.deserializeOptionStr(deserializer),
      grantedRoots: TraitHelpers.deserializeVectorStr(deserializer),
      address: deserializer.deserializeString(),
      pairedAtMs: deserializer.deserializeInt64(),
      verifiedAtMs: TraitHelpers.deserializeOptionI64(deserializer),
      notBeforeMs: deserializer.deserializeInt64(),
      notAfterMs: deserializer.deserializeInt64(),
      expiryNote: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static DeviceView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = DeviceView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String deviceId;
  final String name;
  final String? commonName;
  final List<String> grantedRoots;
  final String address;
  final int pairedAtMs;
  final int? verifiedAtMs;
  final int notBeforeMs;
  final int notAfterMs;
  final String? expiryNote;

  DeviceView copyWith({
    String? deviceId,
    String? name,
    String? Function()? commonName,
    List<String>? grantedRoots,
    String? address,
    int? pairedAtMs,
    int? Function()? verifiedAtMs,
    int? notBeforeMs,
    int? notAfterMs,
    String? Function()? expiryNote,
  }) {
    return DeviceView(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      commonName: commonName == null ? this.commonName : commonName(),
      grantedRoots: grantedRoots ?? this.grantedRoots,
      address: address ?? this.address,
      pairedAtMs: pairedAtMs ?? this.pairedAtMs,
      verifiedAtMs: verifiedAtMs == null ? this.verifiedAtMs : verifiedAtMs(),
      notBeforeMs: notBeforeMs ?? this.notBeforeMs,
      notAfterMs: notAfterMs ?? this.notAfterMs,
      expiryNote: expiryNote == null ? this.expiryNote : expiryNote(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(deviceId);
    serializer.serializeString(name);
    TraitHelpers.serializeOptionStr(commonName, serializer);
    TraitHelpers.serializeVectorStr(grantedRoots, serializer);
    serializer.serializeString(address);
    serializer.serializeInt64(pairedAtMs);
    TraitHelpers.serializeOptionI64(verifiedAtMs, serializer);
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

    return other is DeviceView
      && deviceId == other.deviceId
      && name == other.name
      && commonName == other.commonName
      && listEquals(grantedRoots, other.grantedRoots)
      && address == other.address
      && pairedAtMs == other.pairedAtMs
      && verifiedAtMs == other.verifiedAtMs
      && notBeforeMs == other.notBeforeMs
      && notAfterMs == other.notAfterMs
      && expiryNote == other.expiryNote;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        name,
        commonName,
        grantedRoots,
        address,
        pairedAtMs,
        verifiedAtMs,
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
        'name: $name, '
        'commonName: $commonName, '
        'grantedRoots: $grantedRoots, '
        'address: $address, '
        'pairedAtMs: $pairedAtMs, '
        'verifiedAtMs: $verifiedAtMs, '
        'notBeforeMs: $notBeforeMs, '
        'notAfterMs: $notAfterMs, '
        'expiryNote: $expiryNote'
        ')';
      return true;
    }());

    return fullString ?? 'DeviceView';
  }
}
