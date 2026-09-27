// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A conflict row's whole mutable state: its choice and its outcome, for
/// the row at `index` of the plan's conflicts.
@immutable
class ConflictRowUpdateView {
  const ConflictRowUpdateView({
    required this.index,
    required this.choice,
    this.outcome,
  });

  static ConflictRowUpdateView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictRowUpdateView(
      index: deserializer.deserializeUint32(),
      choice: ConflictChoiceViewExtension.deserialize(deserializer),
      outcome: TraitHelpers.deserializeOptionResultView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ConflictRowUpdateView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ConflictRowUpdateView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int index;
  final ConflictChoiceView choice;
  final ResultView? outcome;

  ConflictRowUpdateView copyWith({
    int? index,
    ConflictChoiceView? choice,
    ResultView? Function()? outcome,
  }) {
    return ConflictRowUpdateView(
      index: index ?? this.index,
      choice: choice ?? this.choice,
      outcome: outcome == null ? this.outcome : outcome(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(index);
    choice.serialize(serializer);
    TraitHelpers.serializeOptionResultView(outcome, serializer);
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

    return other is ConflictRowUpdateView
      && index == other.index
      && choice == other.choice
      && outcome == other.outcome;
  }

  @override
  int get hashCode => Object.hash(
        index,
        choice,
        outcome,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'index: $index, '
        'choice: $choice, '
        'outcome: $outcome'
        ')';
      return true;
    }());

    return fullString ?? 'ConflictRowUpdateView';
  }
}
