// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// An action row's whole mutable state: its choice and its outcome, for
/// the row at `index` of the plan's actions.
@immutable
class ActionRowUpdateView {
  const ActionRowUpdateView({
    required this.index,
    required this.choice,
    this.outcome,
  });

  static ActionRowUpdateView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ActionRowUpdateView(
      index: deserializer.deserializeUint32(),
      choice: ActionChoiceViewExtension.deserialize(deserializer),
      outcome: TraitHelpers.deserializeOptionResultView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ActionRowUpdateView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ActionRowUpdateView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int index;
  final ActionChoiceView choice;
  final ResultView? outcome;

  ActionRowUpdateView copyWith({
    int? index,
    ActionChoiceView? choice,
    ResultView? Function()? outcome,
  }) {
    return ActionRowUpdateView(
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

    return other is ActionRowUpdateView
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

    return fullString ?? 'ActionRowUpdateView';
  }
}
