// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One side's share of SPEC §10's overwrite-guard verdict: how many files
/// the run overwrites there, how many of those it empties to 0 bytes, out
/// of how many its archive holds.
@immutable
class MassOverwriteView {
  const MassOverwriteView({
    required this.side,
    required this.overwrites,
    required this.truncated,
    required this.archived,
  });

  static MassOverwriteView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MassOverwriteView(
      side: SideViewExtension.deserialize(deserializer),
      overwrites: deserializer.deserializeUint64(),
      truncated: deserializer.deserializeUint64(),
      archived: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MassOverwriteView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MassOverwriteView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final SideView side;
  final Uint64 overwrites;
  final Uint64 truncated;
  final Uint64 archived;

  MassOverwriteView copyWith({
    SideView? side,
    Uint64? overwrites,
    Uint64? truncated,
    Uint64? archived,
  }) {
    return MassOverwriteView(
      side: side ?? this.side,
      overwrites: overwrites ?? this.overwrites,
      truncated: truncated ?? this.truncated,
      archived: archived ?? this.archived,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    side.serialize(serializer);
    serializer.serializeUint64(overwrites);
    serializer.serializeUint64(truncated);
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

    return other is MassOverwriteView
      && side == other.side
      && overwrites == other.overwrites
      && truncated == other.truncated
      && archived == other.archived;
  }

  @override
  int get hashCode => Object.hash(
        side,
        overwrites,
        truncated,
        archived,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side, '
        'overwrites: $overwrites, '
        'truncated: $truncated, '
        'archived: $archived'
        ')';
      return true;
    }());

    return fullString ?? 'MassOverwriteView';
  }
}
