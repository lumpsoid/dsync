// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One conflict: the conflict, the choices it offers (a side with no
/// record of the path cannot be kept; keeping both needs a file on both
/// sides), what the review chose, and the outcome of what that applied.
@immutable
class ConflictRowView {
  const ConflictRowView({
    required this.conflict,
    required this.offered,
    required this.offer,
    required this.choice,
    this.outcome,
  });

  static ConflictRowView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictRowView(
      conflict: ConflictView.deserialize(deserializer),
      offered: TraitHelpers.deserializeVectorConflictChoiceView(deserializer),
      offer: OfferView.deserialize(deserializer),
      choice: ConflictChoiceViewExtension.deserialize(deserializer),
      outcome: TraitHelpers.deserializeOptionResultView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ConflictRowView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ConflictRowView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final ConflictView conflict;
  final List<ConflictChoiceView> offered;
  final OfferView offer;
  final ConflictChoiceView choice;
  final ResultView? outcome;

  ConflictRowView copyWith({
    ConflictView? conflict,
    List<ConflictChoiceView>? offered,
    OfferView? offer,
    ConflictChoiceView? choice,
    ResultView? Function()? outcome,
  }) {
    return ConflictRowView(
      conflict: conflict ?? this.conflict,
      offered: offered ?? this.offered,
      offer: offer ?? this.offer,
      choice: choice ?? this.choice,
      outcome: outcome == null ? this.outcome : outcome(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    conflict.serialize(serializer);
    TraitHelpers.serializeVectorConflictChoiceView(offered, serializer);
    offer.serialize(serializer);
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

    return other is ConflictRowView
      && conflict == other.conflict
      && listEquals(offered, other.offered)
      && offer == other.offer
      && choice == other.choice
      && outcome == other.outcome;
  }

  @override
  int get hashCode => Object.hash(
        conflict,
        offered,
        offer,
        choice,
        outcome,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'conflict: $conflict, '
        'offered: $offered, '
        'offer: $offer, '
        'choice: $choice, '
        'outcome: $outcome'
        ')';
      return true;
    }());

    return fullString ?? 'ConflictRowView';
  }
}
