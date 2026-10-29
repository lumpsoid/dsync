// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One planned action: the proposal, what the review chose for it, and its
/// outcome once reported.
@immutable
class PlanRowView {
  const PlanRowView({
    required this.proposal,
    required this.choice,
    this.outcome,
    this.changed,
  });

  static PlanRowView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PlanRowView(
      proposal: ProposalView.deserialize(deserializer),
      choice: ActionChoiceViewExtension.deserialize(deserializer),
      outcome: TraitHelpers.deserializeOptionResultView(deserializer),
      changed: TraitHelpers.deserializeOptionActionChangeView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static PlanRowView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PlanRowView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final ProposalView proposal;
  final ActionChoiceView choice;
  final ResultView? outcome;
  final ActionChangeView? changed;

  PlanRowView copyWith({
    ProposalView? proposal,
    ActionChoiceView? choice,
    ResultView? Function()? outcome,
    ActionChangeView? Function()? changed,
  }) {
    return PlanRowView(
      proposal: proposal ?? this.proposal,
      choice: choice ?? this.choice,
      outcome: outcome == null ? this.outcome : outcome(),
      changed: changed == null ? this.changed : changed(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    proposal.serialize(serializer);
    choice.serialize(serializer);
    TraitHelpers.serializeOptionResultView(outcome, serializer);
    TraitHelpers.serializeOptionActionChangeView(changed, serializer);
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

    return other is PlanRowView
      && proposal == other.proposal
      && choice == other.choice
      && outcome == other.outcome
      && changed == other.changed;
  }

  @override
  int get hashCode => Object.hash(
        proposal,
        choice,
        outcome,
        changed,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'proposal: $proposal, '
        'choice: $choice, '
        'outcome: $outcome, '
        'changed: $changed'
        ')';
      return true;
    }());

    return fullString ?? 'PlanRowView';
  }
}
