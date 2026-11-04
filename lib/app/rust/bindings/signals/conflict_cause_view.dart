// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// [`ConflictCause`]: why the path is a conflict.
abstract class ConflictCauseView {
  const ConflictCauseView();

  void serialize(BinarySerializer serializer);

  static ConflictCauseView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ConflictCauseViewChanges.load(deserializer);
      case 1: return ConflictCauseViewUnfinishedWrite.load(deserializer);
      default: throw Exception('Unknown variant index for ConflictCauseView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ConflictCauseView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ConflictCauseView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ConflictCauseViewChanges extends ConflictCauseView {
  const ConflictCauseViewChanges(
  ) : super();

  static ConflictCauseViewChanges load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictCauseViewChanges(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ConflictCauseViewChanges;
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

    return fullString ?? 'ConflictCauseViewChanges';
  }
}

@immutable
class ConflictCauseViewUnfinishedWrite extends ConflictCauseView {
  const ConflictCauseViewUnfinishedWrite({
    required this.value,
  }) : super();

  static ConflictCauseViewUnfinishedWrite load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictCauseViewUnfinishedWrite(
      value: SideViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SideView value;

  ConflictCauseViewUnfinishedWrite copyWith({
    SideView? value,
  }) {
    return ConflictCauseViewUnfinishedWrite(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ConflictCauseViewUnfinishedWrite
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

    return fullString ?? 'ConflictCauseViewUnfinishedWrite';
  }
}
