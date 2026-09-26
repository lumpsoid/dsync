// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The review's running total: the plan's actions that will be applied
/// (reversed ones included) and how many are reversed or skipped; the
/// conflicts settled toward a side, kept both, or left open.
@immutable
class DecisionSummaryView {
  const DecisionSummaryView({
    required this.apply,
    required this.reversed,
    required this.skipped,
    required this.resolved,
    required this.keptBoth,
    required this.leftOpen,
  });

  static DecisionSummaryView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = DecisionSummaryView(
      apply: deserializer.deserializeUint64(),
      reversed: deserializer.deserializeUint64(),
      skipped: deserializer.deserializeUint64(),
      resolved: deserializer.deserializeUint64(),
      keptBoth: deserializer.deserializeUint64(),
      leftOpen: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static DecisionSummaryView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = DecisionSummaryView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 apply;
  final Uint64 reversed;
  final Uint64 skipped;
  final Uint64 resolved;
  final Uint64 keptBoth;
  final Uint64 leftOpen;

  DecisionSummaryView copyWith({
    Uint64? apply,
    Uint64? reversed,
    Uint64? skipped,
    Uint64? resolved,
    Uint64? keptBoth,
    Uint64? leftOpen,
  }) {
    return DecisionSummaryView(
      apply: apply ?? this.apply,
      reversed: reversed ?? this.reversed,
      skipped: skipped ?? this.skipped,
      resolved: resolved ?? this.resolved,
      keptBoth: keptBoth ?? this.keptBoth,
      leftOpen: leftOpen ?? this.leftOpen,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(apply);
    serializer.serializeUint64(reversed);
    serializer.serializeUint64(skipped);
    serializer.serializeUint64(resolved);
    serializer.serializeUint64(keptBoth);
    serializer.serializeUint64(leftOpen);
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

    return other is DecisionSummaryView
      && apply == other.apply
      && reversed == other.reversed
      && skipped == other.skipped
      && resolved == other.resolved
      && keptBoth == other.keptBoth
      && leftOpen == other.leftOpen;
  }

  @override
  int get hashCode => Object.hash(
        apply,
        reversed,
        skipped,
        resolved,
        keptBoth,
        leftOpen,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'apply: $apply, '
        'reversed: $reversed, '
        'skipped: $skipped, '
        'resolved: $resolved, '
        'keptBoth: $keptBoth, '
        'leftOpen: $leftOpen'
        ')';
      return true;
    }());

    return fullString ?? 'DecisionSummaryView';
  }
}
