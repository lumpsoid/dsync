// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A run of changes with their context; the starts are 1-based line
/// numbers, as [`Hunk`]'s.
@immutable
class HunkView {
  const HunkView({
    required this.oldStart,
    required this.newStart,
    required this.blocks,
  });

  static HunkView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = HunkView(
      oldStart: deserializer.deserializeUint32(),
      newStart: deserializer.deserializeUint32(),
      blocks: TraitHelpers.deserializeVectorBlockView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static HunkView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = HunkView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int oldStart;
  final int newStart;
  final List<BlockView> blocks;

  HunkView copyWith({
    int? oldStart,
    int? newStart,
    List<BlockView>? blocks,
  }) {
    return HunkView(
      oldStart: oldStart ?? this.oldStart,
      newStart: newStart ?? this.newStart,
      blocks: blocks ?? this.blocks,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(oldStart);
    serializer.serializeUint32(newStart);
    TraitHelpers.serializeVectorBlockView(blocks, serializer);
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

    return other is HunkView
      && oldStart == other.oldStart
      && newStart == other.newStart
      && listEquals(blocks, other.blocks);
  }

  @override
  int get hashCode => Object.hash(
        oldStart,
        newStart,
        blocks,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'oldStart: $oldStart, '
        'newStart: $newStart, '
        'blocks: $blocks'
        ')';
      return true;
    }());

    return fullString ?? 'HunkView';
  }
}
