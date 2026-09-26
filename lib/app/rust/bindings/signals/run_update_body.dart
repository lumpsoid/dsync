// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// SPEC §11.4's events, as the head shows them. The per-action ones
/// (approved actions, results, progress) arrive as [`RunUpdateBody::Applied`]
/// batches, at most one per 50 ms; every other update flushes the batch
/// before it, so the order is the run's.
abstract class RunUpdateBody {
  const RunUpdateBody();

  void serialize(BinarySerializer serializer);

  static RunUpdateBody deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return RunUpdateBodyConnected.load(deserializer);
      case 1: return RunUpdateBodyReplicas.load(deserializer);
      case 2: return RunUpdateBodyScanTally.load(deserializer);
      case 3: return RunUpdateBodySkipped.load(deserializer);
      case 4: return RunUpdateBodyConflict.load(deserializer);
      case 5: return RunUpdateBodyPlan.load(deserializer);
      case 6: return RunUpdateBodyMassDelete.load(deserializer);
      case 7: return RunUpdateBodyApplied.load(deserializer);
      case 8: return RunUpdateBodySummary.load(deserializer);
      case 9: return RunUpdateBodyError.load(deserializer);
      case 10: return RunUpdateBodyEnded.load(deserializer);
      default: throw Exception('Unknown variant index for RunUpdateBody: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static RunUpdateBody bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunUpdateBody.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class RunUpdateBodyConnected extends RunUpdateBody {
  const RunUpdateBodyConnected({
    required this.peers,
  }) : super();

  static RunUpdateBodyConnected load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyConnected(
      peers: TraitHelpers.deserializeVectorPeerContactView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<PeerContactView> peers;

  RunUpdateBodyConnected copyWith({
    List<PeerContactView>? peers,
  }) {
    return RunUpdateBodyConnected(
      peers: peers ?? this.peers,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    TraitHelpers.serializeVectorPeerContactView(peers, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyConnected
      && listEquals(peers, other.peers);
  }

  @override
  int get hashCode => peers.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'peers: $peers'
        ')';
      return true;
    }());

    return fullString ?? 'RunUpdateBodyConnected';
  }
}

@immutable
class RunUpdateBodyReplicas extends RunUpdateBody {
  const RunUpdateBodyReplicas({
    required this.a,
    required this.b,
    required this.lastRunUnfinished,
  }) : super();

  static RunUpdateBodyReplicas load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyReplicas(
      a: ReplicaInfoView.deserialize(deserializer),
      b: ReplicaInfoView.deserialize(deserializer),
      lastRunUnfinished: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ReplicaInfoView a;
  final ReplicaInfoView b;
  final bool lastRunUnfinished;

  RunUpdateBodyReplicas copyWith({
    ReplicaInfoView? a,
    ReplicaInfoView? b,
    bool? lastRunUnfinished,
  }) {
    return RunUpdateBodyReplicas(
      a: a ?? this.a,
      b: b ?? this.b,
      lastRunUnfinished: lastRunUnfinished ?? this.lastRunUnfinished,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    a.serialize(serializer);
    b.serialize(serializer);
    serializer.serializeBool(lastRunUnfinished);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyReplicas
      && a == other.a
      && b == other.b
      && lastRunUnfinished == other.lastRunUnfinished;
  }

  @override
  int get hashCode => Object.hash(
        a,
        b,
        lastRunUnfinished,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'a: $a, '
        'b: $b, '
        'lastRunUnfinished: $lastRunUnfinished'
        ')';
      return true;
    }());

    return fullString ?? 'RunUpdateBodyReplicas';
  }
}

@immutable
class RunUpdateBodyScanTally extends RunUpdateBody {
  const RunUpdateBodyScanTally({
    required this.a,
    required this.b,
  }) : super();

  static RunUpdateBodyScanTally load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyScanTally(
      a: TallyView.deserialize(deserializer),
      b: TallyView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final TallyView a;
  final TallyView b;

  RunUpdateBodyScanTally copyWith({
    TallyView? a,
    TallyView? b,
  }) {
    return RunUpdateBodyScanTally(
      a: a ?? this.a,
      b: b ?? this.b,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    a.serialize(serializer);
    b.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyScanTally
      && a == other.a
      && b == other.b;
  }

  @override
  int get hashCode => Object.hash(
        a,
        b,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'a: $a, '
        'b: $b'
        ')';
      return true;
    }());

    return fullString ?? 'RunUpdateBodyScanTally';
  }
}

@immutable
class RunUpdateBodySkipped extends RunUpdateBody {
  const RunUpdateBodySkipped({
    required this.value,
  }) : super();

  static RunUpdateBodySkipped load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodySkipped(
      value: SkippedView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SkippedView value;

  RunUpdateBodySkipped copyWith({
    SkippedView? value,
  }) {
    return RunUpdateBodySkipped(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodySkipped
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

    return fullString ?? 'RunUpdateBodySkipped';
  }
}

@immutable
class RunUpdateBodyConflict extends RunUpdateBody {
  const RunUpdateBodyConflict({
    required this.value,
  }) : super();

  static RunUpdateBodyConflict load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyConflict(
      value: ConflictView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ConflictView value;

  RunUpdateBodyConflict copyWith({
    ConflictView? value,
  }) {
    return RunUpdateBodyConflict(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyConflict
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

    return fullString ?? 'RunUpdateBodyConflict';
  }
}

@immutable
class RunUpdateBodyPlan extends RunUpdateBody {
  const RunUpdateBodyPlan({
    required this.actions,
    required this.conflicts,
    required this.bytesToTransfer,
    required this.exceedsWarnSize,
    required this.awaitingDecision,
  }) : super();

  static RunUpdateBodyPlan load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyPlan(
      actions: TraitHelpers.deserializeVectorProposalView(deserializer),
      conflicts: TraitHelpers.deserializeVectorConflictView(deserializer),
      bytesToTransfer: deserializer.deserializeUint64(),
      exceedsWarnSize: deserializer.deserializeBool(),
      awaitingDecision: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<ProposalView> actions;
  final List<ConflictView> conflicts;
  final Uint64 bytesToTransfer;
  final bool exceedsWarnSize;
  final bool awaitingDecision;

  RunUpdateBodyPlan copyWith({
    List<ProposalView>? actions,
    List<ConflictView>? conflicts,
    Uint64? bytesToTransfer,
    bool? exceedsWarnSize,
    bool? awaitingDecision,
  }) {
    return RunUpdateBodyPlan(
      actions: actions ?? this.actions,
      conflicts: conflicts ?? this.conflicts,
      bytesToTransfer: bytesToTransfer ?? this.bytesToTransfer,
      exceedsWarnSize: exceedsWarnSize ?? this.exceedsWarnSize,
      awaitingDecision: awaitingDecision ?? this.awaitingDecision,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    TraitHelpers.serializeVectorProposalView(actions, serializer);
    TraitHelpers.serializeVectorConflictView(conflicts, serializer);
    serializer.serializeUint64(bytesToTransfer);
    serializer.serializeBool(exceedsWarnSize);
    serializer.serializeBool(awaitingDecision);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyPlan
      && listEquals(actions, other.actions)
      && listEquals(conflicts, other.conflicts)
      && bytesToTransfer == other.bytesToTransfer
      && exceedsWarnSize == other.exceedsWarnSize
      && awaitingDecision == other.awaitingDecision;
  }

  @override
  int get hashCode => Object.hash(
        actions,
        conflicts,
        bytesToTransfer,
        exceedsWarnSize,
        awaitingDecision,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'actions: $actions, '
        'conflicts: $conflicts, '
        'bytesToTransfer: $bytesToTransfer, '
        'exceedsWarnSize: $exceedsWarnSize, '
        'awaitingDecision: $awaitingDecision'
        ')';
      return true;
    }());

    return fullString ?? 'RunUpdateBodyPlan';
  }
}

@immutable
class RunUpdateBodyMassDelete extends RunUpdateBody {
  const RunUpdateBodyMassDelete({
    required this.sides,
    required this.awaitingConfirmation,
  }) : super();

  static RunUpdateBodyMassDelete load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyMassDelete(
      sides: TraitHelpers.deserializeVectorMassDeleteView(deserializer),
      awaitingConfirmation: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<MassDeleteView> sides;
  final bool awaitingConfirmation;

  RunUpdateBodyMassDelete copyWith({
    List<MassDeleteView>? sides,
    bool? awaitingConfirmation,
  }) {
    return RunUpdateBodyMassDelete(
      sides: sides ?? this.sides,
      awaitingConfirmation: awaitingConfirmation ?? this.awaitingConfirmation,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    TraitHelpers.serializeVectorMassDeleteView(sides, serializer);
    serializer.serializeBool(awaitingConfirmation);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyMassDelete
      && listEquals(sides, other.sides)
      && awaitingConfirmation == other.awaitingConfirmation;
  }

  @override
  int get hashCode => Object.hash(
        sides,
        awaitingConfirmation,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'sides: $sides, '
        'awaitingConfirmation: $awaitingConfirmation'
        ')';
      return true;
    }());

    return fullString ?? 'RunUpdateBodyMassDelete';
  }
}

@immutable
class RunUpdateBodyApplied extends RunUpdateBody {
  const RunUpdateBodyApplied({
    required this.approved,
    required this.results,
    this.progress,
  }) : super();

  static RunUpdateBodyApplied load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyApplied(
      approved: TraitHelpers.deserializeVectorActionView(deserializer),
      results: TraitHelpers.deserializeVectorResultView(deserializer),
      progress: TraitHelpers.deserializeOptionProgressView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<ActionView> approved;
  final List<ResultView> results;
  final ProgressView? progress;

  RunUpdateBodyApplied copyWith({
    List<ActionView>? approved,
    List<ResultView>? results,
    ProgressView? Function()? progress,
  }) {
    return RunUpdateBodyApplied(
      approved: approved ?? this.approved,
      results: results ?? this.results,
      progress: progress == null ? this.progress : progress(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    TraitHelpers.serializeVectorActionView(approved, serializer);
    TraitHelpers.serializeVectorResultView(results, serializer);
    TraitHelpers.serializeOptionProgressView(progress, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyApplied
      && listEquals(approved, other.approved)
      && listEquals(results, other.results)
      && progress == other.progress;
  }

  @override
  int get hashCode => Object.hash(
        approved,
        results,
        progress,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'approved: $approved, '
        'results: $results, '
        'progress: $progress'
        ')';
      return true;
    }());

    return fullString ?? 'RunUpdateBodyApplied';
  }
}

@immutable
class RunUpdateBodySummary extends RunUpdateBody {
  const RunUpdateBodySummary({
    required this.value,
  }) : super();

  static RunUpdateBodySummary load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodySummary(
      value: SummaryView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SummaryView value;

  RunUpdateBodySummary copyWith({
    SummaryView? value,
  }) {
    return RunUpdateBodySummary(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodySummary
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

    return fullString ?? 'RunUpdateBodySummary';
  }
}

@immutable
class RunUpdateBodyError extends RunUpdateBody {
  const RunUpdateBodyError({
    required this.value,
  }) : super();

  static RunUpdateBodyError load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyError(
      value: RunErrorView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RunErrorView value;

  RunUpdateBodyError copyWith({
    RunErrorView? value,
  }) {
    return RunUpdateBodyError(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(9);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyError
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

    return fullString ?? 'RunUpdateBodyError';
  }
}

@immutable
class RunUpdateBodyEnded extends RunUpdateBody {
  const RunUpdateBodyEnded({
    required this.value,
  }) : super();

  static RunUpdateBodyEnded load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunUpdateBodyEnded(
      value: RunEndView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RunEndView value;

  RunUpdateBodyEnded copyWith({
    RunEndView? value,
  }) {
    return RunUpdateBodyEnded(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunUpdateBodyEnded
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

    return fullString ?? 'RunUpdateBodyEnded';
  }
}
