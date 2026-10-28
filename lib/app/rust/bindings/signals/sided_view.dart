// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One side of a compared path; `size` is `None` when that side has no
/// file (an empty file is `Some(0)`).
@immutable
class SidedView {
  const SidedView({
    required this.side,
    this.size,
  });

  static SidedView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SidedView(
      side: SideViewExtension.deserialize(deserializer),
      size: TraitHelpers.deserializeOptionU64(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SidedView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SidedView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final SideView side;
  final Uint64? size;

  SidedView copyWith({
    SideView? side,
    Uint64? Function()? size,
  }) {
    return SidedView(
      side: side ?? this.side,
      size: size == null ? this.size : size(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    side.serialize(serializer);
    TraitHelpers.serializeOptionU64(size, serializer);
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

    return other is SidedView
      && side == other.side
      && size == other.size;
  }

  @override
  int get hashCode => Object.hash(
        side,
        size,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side, '
        'size: $size'
        ')';
      return true;
    }());

    return fullString ?? 'SidedView';
  }
}
