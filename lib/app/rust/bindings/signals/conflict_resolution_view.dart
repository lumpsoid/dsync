// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// How a conflict is settled: one side's state wins, or both versions are
/// kept - the peer's (side B's) saved beside this device's on side A.
abstract class ConflictResolutionView {
  const ConflictResolutionView();

  void serialize(BinarySerializer serializer);

  static ConflictResolutionView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ConflictResolutionViewKeep.load(deserializer);
      case 1: return ConflictResolutionViewKeepBoth.load(deserializer);
      default: throw Exception('Unknown variant index for ConflictResolutionView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ConflictResolutionView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ConflictResolutionView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ConflictResolutionViewKeep extends ConflictResolutionView {
  const ConflictResolutionViewKeep({
    required this.value,
  }) : super();

  static ConflictResolutionViewKeep load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictResolutionViewKeep(
      value: SideViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SideView value;

  ConflictResolutionViewKeep copyWith({
    SideView? value,
  }) {
    return ConflictResolutionViewKeep(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ConflictResolutionViewKeep
      && value == other.value;
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

    return fullString ?? 'ConflictResolutionViewKeep';
  }
}

@immutable
class ConflictResolutionViewKeepBoth extends ConflictResolutionView {
  const ConflictResolutionViewKeepBoth(
  ) : super();

  static ConflictResolutionViewKeepBoth load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictResolutionViewKeepBoth(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ConflictResolutionViewKeepBoth;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'ConflictResolutionViewKeepBoth';
  }
}
