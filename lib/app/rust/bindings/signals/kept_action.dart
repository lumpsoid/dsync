// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A kept action: `reversed` puts the loser's version back instead of
/// applying the plan's direction. One flag on the index, so "reversed"
/// can never name an index that is not kept.
@immutable
class KeptAction {
  const KeptAction({
    required this.index,
    required this.reversed,
  });

  static KeptAction deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = KeptAction(
      index: deserializer.deserializeUint32(),
      reversed: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static KeptAction bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = KeptAction.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int index;
  final bool reversed;

  KeptAction copyWith({
    int? index,
    bool? reversed,
  }) {
    return KeptAction(
      index: index ?? this.index,
      reversed: reversed ?? this.reversed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(index);
    serializer.serializeBool(reversed);
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

    return other is KeptAction
      && index == other.index
      && reversed == other.reversed;
  }

  @override
  int get hashCode => Object.hash(
        index,
        reversed,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'index: $index, '
        'reversed: $reversed'
        ')';
      return true;
    }());

    return fullString ?? 'KeptAction';
  }
}
