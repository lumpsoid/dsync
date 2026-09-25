// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ConflictChoice {
  const ConflictChoice({
    required this.conflict,
    required this.resolution,
  });

  static ConflictChoice deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictChoice(
      conflict: deserializer.deserializeUint32(),
      resolution: ConflictResolutionView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ConflictChoice bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ConflictChoice.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int conflict;
  final ConflictResolutionView resolution;

  ConflictChoice copyWith({
    int? conflict,
    ConflictResolutionView? resolution,
  }) {
    return ConflictChoice(
      conflict: conflict ?? this.conflict,
      resolution: resolution ?? this.resolution,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(conflict);
    resolution.serialize(serializer);
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

    return other is ConflictChoice
      && conflict == other.conflict
      && resolution == other.resolution;
  }

  @override
  int get hashCode => Object.hash(
        conflict,
        resolution,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'conflict: $conflict, '
        'resolution: $resolution'
        ')';
      return true;
    }());

    return fullString ?? 'ConflictChoice';
  }
}
