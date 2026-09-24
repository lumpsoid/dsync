// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The head's answer to a plan: which of its actions to keep (indices into
/// the plan's actions) and which conflicts to settle, and which way
/// (indices into its conflicts). A conflict left out stays unresolved.
@immutable
class RunDecision {
  const RunDecision({
    required this.keep,
    required this.resolve,
  });

  static RunDecision deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunDecision(
      keep: TraitHelpers.deserializeVectorU32(deserializer),
      resolve: TraitHelpers.deserializeVectorConflictChoice(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RunDecision bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunDecision.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final List<int> keep;
  final List<ConflictChoice> resolve;

  RunDecision copyWith({
    List<int>? keep,
    List<ConflictChoice>? resolve,
  }) {
    return RunDecision(
      keep: keep ?? this.keep,
      resolve: resolve ?? this.resolve,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeVectorU32(keep, serializer);
    TraitHelpers.serializeVectorConflictChoice(resolve, serializer);
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

    return other is RunDecision
      && listEquals(keep, other.keep)
      && listEquals(resolve, other.resolve);
  }

  @override
  int get hashCode => Object.hash(
        keep,
        resolve,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'keep: $keep, '
        'resolve: $resolve'
        ')';
      return true;
    }());

    return fullString ?? 'RunDecision';
  }
}
