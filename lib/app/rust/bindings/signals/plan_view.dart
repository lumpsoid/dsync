// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A plan whole: its rows and the fixed facts about it.
@immutable
class PlanView {
  const PlanView({
    required this.actions,
    required this.conflicts,
    required this.bytesToTransfer,
    this.exceededWarnSizeBytes,
    required this.summary,
  });

  static PlanView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PlanView(
      actions: TraitHelpers.deserializeVectorPlanRowView(deserializer),
      conflicts: TraitHelpers.deserializeVectorConflictRowView(deserializer),
      bytesToTransfer: deserializer.deserializeUint64(),
      exceededWarnSizeBytes: TraitHelpers.deserializeOptionU64(deserializer),
      summary: PlanSummaryView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static PlanView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PlanView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final List<PlanRowView> actions;
  final List<ConflictRowView> conflicts;
  final Uint64 bytesToTransfer;
  final Uint64? exceededWarnSizeBytes;
  final PlanSummaryView summary;

  PlanView copyWith({
    List<PlanRowView>? actions,
    List<ConflictRowView>? conflicts,
    Uint64? bytesToTransfer,
    Uint64? Function()? exceededWarnSizeBytes,
    PlanSummaryView? summary,
  }) {
    return PlanView(
      actions: actions ?? this.actions,
      conflicts: conflicts ?? this.conflicts,
      bytesToTransfer: bytesToTransfer ?? this.bytesToTransfer,
      exceededWarnSizeBytes: exceededWarnSizeBytes == null ? this.exceededWarnSizeBytes : exceededWarnSizeBytes(),
      summary: summary ?? this.summary,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeVectorPlanRowView(actions, serializer);
    TraitHelpers.serializeVectorConflictRowView(conflicts, serializer);
    serializer.serializeUint64(bytesToTransfer);
    TraitHelpers.serializeOptionU64(exceededWarnSizeBytes, serializer);
    summary.serialize(serializer);
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

    return other is PlanView
      && listEquals(actions, other.actions)
      && listEquals(conflicts, other.conflicts)
      && bytesToTransfer == other.bytesToTransfer
      && exceededWarnSizeBytes == other.exceededWarnSizeBytes
      && summary == other.summary;
  }

  @override
  int get hashCode => Object.hash(
        actions,
        conflicts,
        bytesToTransfer,
        exceededWarnSizeBytes,
        summary,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'actions: $actions, '
        'conflicts: $conflicts, '
        'bytesToTransfer: $bytesToTransfer, '
        'exceededWarnSizeBytes: $exceededWarnSizeBytes, '
        'summary: $summary'
        ')';
      return true;
    }());

    return fullString ?? 'PlanView';
  }
}
