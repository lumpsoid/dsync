// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A review row, by its index among the plan's actions or its conflicts.
abstract class RowRef {
  const RowRef();

  void serialize(BinarySerializer serializer);

  static RowRef deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return RowRefAction.load(deserializer);
      case 1: return RowRefConflict.load(deserializer);
      default: throw Exception('Unknown variant index for RowRef: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static RowRef bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RowRef.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class RowRefAction extends RowRef {
  const RowRefAction({
    required this.index,
  }) : super();

  static RowRefAction load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RowRefAction(
      index: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int index;

  RowRefAction copyWith({
    int? index,
  }) {
    return RowRefAction(
      index: index ?? this.index,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeUint32(index);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RowRefAction
      && index == other.index;
  }

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'index: $index'
        ')';
      return true;
    }());

    return fullString ?? 'RowRefAction';
  }
}

@immutable
class RowRefConflict extends RowRef {
  const RowRefConflict({
    required this.index,
  }) : super();

  static RowRefConflict load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RowRefConflict(
      index: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int index;

  RowRefConflict copyWith({
    int? index,
  }) {
    return RowRefConflict(
      index: index ?? this.index,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeUint32(index);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RowRefConflict
      && index == other.index;
  }

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'index: $index'
        ')';
      return true;
    }());

    return fullString ?? 'RowRefConflict';
  }
}
