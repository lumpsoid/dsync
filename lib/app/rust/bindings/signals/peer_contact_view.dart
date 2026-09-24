// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A `peer://` side as dialling found it, with the run header's notes.
@immutable
class PeerContactView {
  const PeerContactView({
    required this.side,
    required this.deviceId,
    required this.address,
    required this.notes,
  });

  static PeerContactView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PeerContactView(
      side: SideViewExtension.deserialize(deserializer),
      deviceId: deserializer.deserializeString(),
      address: deserializer.deserializeString(),
      notes: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static PeerContactView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PeerContactView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final SideView side;
  final String deviceId;
  final String address;
  final List<String> notes;

  PeerContactView copyWith({
    SideView? side,
    String? deviceId,
    String? address,
    List<String>? notes,
  }) {
    return PeerContactView(
      side: side ?? this.side,
      deviceId: deviceId ?? this.deviceId,
      address: address ?? this.address,
      notes: notes ?? this.notes,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    side.serialize(serializer);
    serializer.serializeString(deviceId);
    serializer.serializeString(address);
    TraitHelpers.serializeVectorStr(notes, serializer);
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

    return other is PeerContactView
      && side == other.side
      && deviceId == other.deviceId
      && address == other.address
      && listEquals(notes, other.notes);
  }

  @override
  int get hashCode => Object.hash(
        side,
        deviceId,
        address,
        notes,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side, '
        'deviceId: $deviceId, '
        'address: $address, '
        'notes: $notes'
        ')';
      return true;
    }());

    return fullString ?? 'PeerContactView';
  }
}
