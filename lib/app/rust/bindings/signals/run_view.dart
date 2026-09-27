// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A run as the head shows it, sent after every change. Everything but
/// the plan's rows is whole in every view. The plan is sent whole once -
/// the first view after the hub takes it - and thereafter each view says
/// either the same plan with the rows changed since the view before, no
/// plan, or a new plan, whole: a session's views all reach the head, in
/// order, so it folds each into the last. Built by the run's own state in
/// `run/state.rs`.
///
/// A session runs a profile's entries one after another: `entries` lists
/// them all, `current` is the one running (or that ran last), and every
/// field from `connected_at_ms` on describes that entry alone.
@immutable
class RunView {
  const RunView({
    required this.dryRun,
    required this.phase,
    required this.standing,
    required this.entries,
    this.current,
    this.connectedAtMs,
    this.replicas,
    this.tally,
    required this.skipped,
    required this.plan,
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
      standing: RunStandingViewExtension.deserialize(deserializer),
      entries: TraitHelpers.deserializeVectorEntryRunView(deserializer),
      current: TraitHelpers.deserializeOptionU32(deserializer),
      connectedAtMs: TraitHelpers.deserializeOptionI64(deserializer),
      replicas: TraitHelpers.deserializeOptionReplicasView(deserializer),
      tally: TraitHelpers.deserializeOptionTalliesView(deserializer),
      skipped: TraitHelpers.deserializeVectorSkippedView(deserializer),
      plan: PlanUpdateView.deserialize(deserializer),
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
  final RunStandingView standing;
  final List<EntryRunView> entries;
  final int? current;
  final int? connectedAtMs;
  final ReplicasView? replicas;
  final TalliesView? tally;
  final List<SkippedView> skipped;
  final PlanUpdateView plan;
  final ProgressView? progress;
  final Uint64 applied;
  final Uint64 failed;
  final String? timings;

  RunView copyWith({
    bool? dryRun,
    RunPhaseView? phase,
    RunStandingView? standing,
    List<EntryRunView>? entries,
    int? Function()? current,
    int? Function()? connectedAtMs,
    ReplicasView? Function()? replicas,
    TalliesView? Function()? tally,
    List<SkippedView>? skipped,
    PlanUpdateView? plan,
    ProgressView? Function()? progress,
    Uint64? applied,
    Uint64? failed,
    String? Function()? timings,
  }) {
    return RunView(
      dryRun: dryRun ?? this.dryRun,
      phase: phase ?? this.phase,
      standing: standing ?? this.standing,
      entries: entries ?? this.entries,
      current: current == null ? this.current : current(),
      connectedAtMs: connectedAtMs == null ? this.connectedAtMs : connectedAtMs(),
      replicas: replicas == null ? this.replicas : replicas(),
      tally: tally == null ? this.tally : tally(),
      skipped: skipped ?? this.skipped,
      plan: plan ?? this.plan,
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
    standing.serialize(serializer);
    TraitHelpers.serializeVectorEntryRunView(entries, serializer);
    TraitHelpers.serializeOptionU32(current, serializer);
    TraitHelpers.serializeOptionI64(connectedAtMs, serializer);
    TraitHelpers.serializeOptionReplicasView(replicas, serializer);
    TraitHelpers.serializeOptionTalliesView(tally, serializer);
    TraitHelpers.serializeVectorSkippedView(skipped, serializer);
    plan.serialize(serializer);
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
      && standing == other.standing
      && listEquals(entries, other.entries)
      && current == other.current
      && connectedAtMs == other.connectedAtMs
      && replicas == other.replicas
      && tally == other.tally
      && listEquals(skipped, other.skipped)
      && plan == other.plan
      && progress == other.progress
      && applied == other.applied
      && failed == other.failed
      && timings == other.timings;
  }

  @override
  int get hashCode => Object.hash(
        dryRun,
        phase,
        standing,
        entries,
        current,
        connectedAtMs,
        replicas,
        tally,
        skipped,
        plan,
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
        'standing: $standing, '
        'entries: $entries, '
        'current: $current, '
        'connectedAtMs: $connectedAtMs, '
        'replicas: $replicas, '
        'tally: $tally, '
        'skipped: $skipped, '
        'plan: $plan, '
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
