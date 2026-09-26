// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One side's share of SPEC §10's delete-guard verdict: how many files
/// the run deletes there, out of how many its archive holds.
@immutable
class MassDeleteView {
  const MassDeleteView({
    required this.side,
    required this.deletes,
    required this.archived,
  });

  static MassDeleteView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MassDeleteView(
      side: SideViewExtension.deserialize(deserializer),
      deletes: deserializer.deserializeUint64(),
      archived: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MassDeleteView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MassDeleteView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final SideView side;
  final Uint64 deletes;
  final Uint64 archived;

  MassDeleteView copyWith({
    SideView? side,
    Uint64? deletes,
    Uint64? archived,
  }) {
    return MassDeleteView(
      side: side ?? this.side,
      deletes: deletes ?? this.deletes,
      archived: archived ?? this.archived,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    side.serialize(serializer);
    serializer.serializeUint64(deletes);
    serializer.serializeUint64(archived);
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

    return other is MassDeleteView
      && side == other.side
      && deletes == other.deletes
      && archived == other.archived;
  }

  @override
  int get hashCode => Object.hash(
        side,
        deletes,
        archived,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side, '
        'deletes: $deletes, '
        'archived: $archived'
        ')';
      return true;
    }());

    return fullString ?? 'MassDeleteView';
  }
}
