// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class BlockView {
  const BlockView();

  void serialize(BinarySerializer serializer);

  static BlockView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return BlockViewSame.load(deserializer);
      case 1: return BlockViewChanged.load(deserializer);
      default: throw Exception('Unknown variant index for BlockView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static BlockView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = BlockView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class BlockViewSame extends BlockView {
  const BlockViewSame({
    required this.value,
  }) : super();

  static BlockViewSame load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = BlockViewSame(
      value: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<String> value;

  BlockViewSame copyWith({
    List<String>? value,
  }) {
    return BlockViewSame(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    TraitHelpers.serializeVectorStr(value, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is BlockViewSame
      && listEquals(value, other.value);
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'value: $value'
        ')';
      return true;
    }());

    return fullString ?? 'BlockViewSame';
  }
}

@immutable
class BlockViewChanged extends BlockView {
  const BlockViewChanged({
    required this.oldLines,
    required this.newLines,
  }) : super();

  static BlockViewChanged load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = BlockViewChanged(
      oldLines: TraitHelpers.deserializeVectorLineView(deserializer),
      newLines: TraitHelpers.deserializeVectorLineView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<LineView> oldLines;
  final List<LineView> newLines;

  BlockViewChanged copyWith({
    List<LineView>? oldLines,
    List<LineView>? newLines,
  }) {
    return BlockViewChanged(
      oldLines: oldLines ?? this.oldLines,
      newLines: newLines ?? this.newLines,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    TraitHelpers.serializeVectorLineView(oldLines, serializer);
    TraitHelpers.serializeVectorLineView(newLines, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is BlockViewChanged
      && listEquals(oldLines, other.oldLines)
      && listEquals(newLines, other.newLines);
  }

  @override
  int get hashCode => Object.hash(
        oldLines,
        newLines,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'oldLines: $oldLines, '
        'newLines: $newLines'
        ')';
      return true;
    }());

    return fullString ?? 'BlockViewChanged';
  }
}
