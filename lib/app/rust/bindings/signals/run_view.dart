// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A run as the head shows it, whole: sent after every change, so each
/// one stands alone and the head renders the latest without folding
/// anything. Built by the run's own state in `run/state.rs`.
@immutable
class RunView {
  const RunView({
    required this.dryRun,
    required this.phase,
    this.connectedAtMs,
    this.replicas,
    this.tally,
    required this.skipped,
    required this.conflicts,
    required this.plan,
    required this.bytesToTransfer,
    this.progress,
    required this.applied,
    required this.failed,
    this.timings,
  });

  static RunView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunView(
      dryRun: deserializer.deserializeBool(),
      phase: RunPhaseView.deserialize(deserializer),
      connectedAtMs: TraitHelpers.deserializeOptionI64(deserializer),
      replicas: TraitHelpers.deserializeOptionReplicasView(deserializer),
      tally: TraitHelpers.deserializeOptionTalliesView(deserializer),
      skipped: TraitHelpers.deserializeVectorSkippedView(deserializer),
      conflicts: TraitHelpers.deserializeVectorConflictRowView(deserializer),
      plan: TraitHelpers.deserializeVectorPlanRowView(deserializer),
      bytesToTransfer: deserializer.deserializeUint64(),
      progress: TraitHelpers.deserializeOptionProgressView(deserializer),
      applied: deserializer.deserializeUint64(),
      failed: deserializer.deserializeUint64(),
      timings: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RunView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final bool dryRun;
  final RunPhaseView phase;
  final int? connectedAtMs;
  final ReplicasView? replicas;
  final TalliesView? tally;
  final List<SkippedView> skipped;
  final List<ConflictRowView> conflicts;
  final List<PlanRowView> plan;
  final Uint64 bytesToTransfer;
  final ProgressView? progress;
  final Uint64 applied;
  final Uint64 failed;
  final String? timings;

  RunView copyWith({
    bool? dryRun,
    RunPhaseView? phase,
    int? Function()? connectedAtMs,
    ReplicasView? Function()? replicas,
    TalliesView? Function()? tally,
    List<SkippedView>? skipped,
    List<ConflictRowView>? conflicts,
    List<PlanRowView>? plan,
    Uint64? bytesToTransfer,
    ProgressView? Function()? progress,
    Uint64? applied,
    Uint64? failed,
    String? Function()? timings,
  }) {
    return RunView(
      dryRun: dryRun ?? this.dryRun,
      phase: phase ?? this.phase,
      connectedAtMs: connectedAtMs == null ? this.connectedAtMs : connectedAtMs(),
      replicas: replicas == null ? this.replicas : replicas(),
      tally: tally == null ? this.tally : tally(),
      skipped: skipped ?? this.skipped,
      conflicts: conflicts ?? this.conflicts,
      plan: plan ?? this.plan,
      bytesToTransfer: bytesToTransfer ?? this.bytesToTransfer,
      progress: progress == null ? this.progress : progress(),
      applied: applied ?? this.applied,
      failed: failed ?? this.failed,
      timings: timings == null ? this.timings : timings(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeBool(dryRun);
    phase.serialize(serializer);
    TraitHelpers.serializeOptionI64(connectedAtMs, serializer);
    TraitHelpers.serializeOptionReplicasView(replicas, serializer);
    TraitHelpers.serializeOptionTalliesView(tally, serializer);
    TraitHelpers.serializeVectorSkippedView(skipped, serializer);
    TraitHelpers.serializeVectorConflictRowView(conflicts, serializer);
    TraitHelpers.serializeVectorPlanRowView(plan, serializer);
    serializer.serializeUint64(bytesToTransfer);
    TraitHelpers.serializeOptionProgressView(progress, serializer);
    serializer.serializeUint64(applied);
    serializer.serializeUint64(failed);
    TraitHelpers.serializeOptionStr(timings, serializer);
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

    return other is RunView
      && dryRun == other.dryRun
      && phase == other.phase
      && connectedAtMs == other.connectedAtMs
      && replicas == other.replicas
      && tally == other.tally
      && listEquals(skipped, other.skipped)
      && listEquals(conflicts, other.conflicts)
      && listEquals(plan, other.plan)
      && bytesToTransfer == other.bytesToTransfer
      && progress == other.progress
      && applied == other.applied
      && failed == other.failed
      && timings == other.timings;
  }

  @override
  int get hashCode => Object.hash(
        dryRun,
        phase,
        connectedAtMs,
        replicas,
        tally,
        skipped,
        conflicts,
        plan,
        bytesToTransfer,
        progress,
        applied,
        failed,
        timings,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'dryRun: $dryRun, '
        'phase: $phase, '
        'connectedAtMs: $connectedAtMs, '
        'replicas: $replicas, '
        'tally: $tally, '
        'skipped: $skipped, '
        'conflicts: $conflicts, '
        'plan: $plan, '
        'bytesToTransfer: $bytesToTransfer, '
        'progress: $progress, '
        'applied: $applied, '
        'failed: $failed, '
        'timings: $timings'
        ')';
      return true;
    }());

    return fullString ?? 'RunView';
  }
}
