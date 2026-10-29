// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Where a run stands. The live ones are `Connecting` to `Applying`;
/// `Finished` and `Stopped` end the session; the rest wait on a resume.
abstract class RunPhaseView {
  const RunPhaseView();

  void serialize(BinarySerializer serializer);

  static RunPhaseView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return RunPhaseViewConnecting.load(deserializer);
      case 1: return RunPhaseViewReconnecting.load(deserializer);
      case 2: return RunPhaseViewScanning.load(deserializer);
      case 3: return RunPhaseViewReviewing.load(deserializer);
      case 4: return RunPhaseViewConfirmingDeletes.load(deserializer);
      case 5: return RunPhaseViewApplying.load(deserializer);
      case 6: return RunPhaseViewFinished.load(deserializer);
      case 7: return RunPhaseViewStopped.load(deserializer);
      case 8: return RunPhaseViewPaused.load(deserializer);
      case 9: return RunPhaseViewFailed.load(deserializer);
      case 10: return RunPhaseViewReplicaBusy.load(deserializer);
      case 11: return RunPhaseViewDeletesDeclined.load(deserializer);
      case 12: return RunPhaseViewNoSummary.load(deserializer);
      case 13: return RunPhaseViewFinishedWithIssues.load(deserializer);
      default: throw Exception('Unknown variant index for RunPhaseView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static RunPhaseView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunPhaseView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class RunPhaseViewConnecting extends RunPhaseView {
  const RunPhaseViewConnecting(
  ) : super();

  static RunPhaseViewConnecting load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewConnecting(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewConnecting;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewConnecting';
  }
}

@immutable
class RunPhaseViewReconnecting extends RunPhaseView {
  const RunPhaseViewReconnecting({
    required this.attempt,
    required this.nextInMs,
  }) : super();

  static RunPhaseViewReconnecting load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewReconnecting(
      attempt: deserializer.deserializeUint32(),
      nextInMs: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int attempt;
  final Uint64 nextInMs;

  RunPhaseViewReconnecting copyWith({
    int? attempt,
    Uint64? nextInMs,
  }) {
    return RunPhaseViewReconnecting(
      attempt: attempt ?? this.attempt,
      nextInMs: nextInMs ?? this.nextInMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeUint32(attempt);
    serializer.serializeUint64(nextInMs);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewReconnecting
      && attempt == other.attempt
      && nextInMs == other.nextInMs;
  }

  @override
  int get hashCode => Object.hash(
        attempt,
        nextInMs,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'attempt: $attempt, '
        'nextInMs: $nextInMs'
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewReconnecting';
  }
}

@immutable
class RunPhaseViewScanning extends RunPhaseView {
  const RunPhaseViewScanning(
  ) : super();

  static RunPhaseViewScanning load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewScanning(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewScanning;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewScanning';
  }
}

@immutable
class RunPhaseViewReviewing extends RunPhaseView {
  const RunPhaseViewReviewing({
    required this.value,
  }) : super();

  static RunPhaseViewReviewing load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewReviewing(
      value: DecisionSummaryView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final DecisionSummaryView value;

  RunPhaseViewReviewing copyWith({
    DecisionSummaryView? value,
  }) {
    return RunPhaseViewReviewing(
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

    return other is RunPhaseViewReviewing
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

    return fullString ?? 'RunPhaseViewReviewing';
  }
}

@immutable
class RunPhaseViewConfirmingDeletes extends RunPhaseView {
  const RunPhaseViewConfirmingDeletes({
    required this.sides,
  }) : super();

  static RunPhaseViewConfirmingDeletes load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewConfirmingDeletes(
      sides: TraitHelpers.deserializeVectorMassDeleteView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<MassDeleteView> sides;

  RunPhaseViewConfirmingDeletes copyWith({
    List<MassDeleteView>? sides,
  }) {
    return RunPhaseViewConfirmingDeletes(
      sides: sides ?? this.sides,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    TraitHelpers.serializeVectorMassDeleteView(sides, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewConfirmingDeletes
      && listEquals(sides, other.sides);
  }

  @override
  int get hashCode => sides.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'sides: $sides'
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewConfirmingDeletes';
  }
}

@immutable
class RunPhaseViewApplying extends RunPhaseView {
  const RunPhaseViewApplying(
  ) : super();

  static RunPhaseViewApplying load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewApplying(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewApplying;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewApplying';
  }
}

@immutable
class RunPhaseViewFinished extends RunPhaseView {
  const RunPhaseViewFinished({
    required this.value,
  }) : super();

  static RunPhaseViewFinished load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewFinished(
      value: SummaryView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SummaryView value;

  RunPhaseViewFinished copyWith({
    SummaryView? value,
  }) {
    return RunPhaseViewFinished(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewFinished
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

    return fullString ?? 'RunPhaseViewFinished';
  }
}

@immutable
class RunPhaseViewStopped extends RunPhaseView {
  const RunPhaseViewStopped({
    required this.completed,
  }) : super();

  static RunPhaseViewStopped load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewStopped(
      completed: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 completed;

  RunPhaseViewStopped copyWith({
    Uint64? completed,
  }) {
    return RunPhaseViewStopped(
      completed: completed ?? this.completed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    serializer.serializeUint64(completed);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewStopped
      && completed == other.completed;
  }

  @override
  int get hashCode => completed.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'completed: $completed'
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewStopped';
  }
}

@immutable
class RunPhaseViewPaused extends RunPhaseView {
  const RunPhaseViewPaused({
    required this.completed,
  }) : super();

  static RunPhaseViewPaused load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewPaused(
      completed: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 completed;

  RunPhaseViewPaused copyWith({
    Uint64? completed,
  }) {
    return RunPhaseViewPaused(
      completed: completed ?? this.completed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    serializer.serializeUint64(completed);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewPaused
      && completed == other.completed;
  }

  @override
  int get hashCode => completed.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'completed: $completed'
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewPaused';
  }
}

@immutable
class RunPhaseViewFailed extends RunPhaseView {
  const RunPhaseViewFailed({
    required this.message,
  }) : super();

  static RunPhaseViewFailed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewFailed(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  RunPhaseViewFailed copyWith({
    String? message,
  }) {
    return RunPhaseViewFailed(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(9);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewFailed
      && message == other.message;
  }

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewFailed';
  }
}

@immutable
class RunPhaseViewReplicaBusy extends RunPhaseView {
  const RunPhaseViewReplicaBusy({
    required this.message,
  }) : super();

  static RunPhaseViewReplicaBusy load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewReplicaBusy(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  RunPhaseViewReplicaBusy copyWith({
    String? message,
  }) {
    return RunPhaseViewReplicaBusy(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewReplicaBusy
      && message == other.message;
  }

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewReplicaBusy';
  }
}

@immutable
class RunPhaseViewDeletesDeclined extends RunPhaseView {
  const RunPhaseViewDeletesDeclined(
  ) : super();

  static RunPhaseViewDeletesDeclined load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewDeletesDeclined(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(11);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewDeletesDeclined;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewDeletesDeclined';
  }
}

@immutable
class RunPhaseViewNoSummary extends RunPhaseView {
  const RunPhaseViewNoSummary(
  ) : super();

  static RunPhaseViewNoSummary load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewNoSummary(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(12);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewNoSummary;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewNoSummary';
  }
}

@immutable
class RunPhaseViewFinishedWithIssues extends RunPhaseView {
  const RunPhaseViewFinishedWithIssues({
    required this.entries,
  }) : super();

  static RunPhaseViewFinishedWithIssues load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunPhaseViewFinishedWithIssues(
      entries: TraitHelpers.deserializeVectorEntryIssueView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<EntryIssueView> entries;

  RunPhaseViewFinishedWithIssues copyWith({
    List<EntryIssueView>? entries,
  }) {
    return RunPhaseViewFinishedWithIssues(
      entries: entries ?? this.entries,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(13);
    TraitHelpers.serializeVectorEntryIssueView(entries, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunPhaseViewFinishedWithIssues
      && listEquals(entries, other.entries);
  }

  @override
  int get hashCode => entries.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'entries: $entries'
        ')';
      return true;
    }());

    return fullString ?? 'RunPhaseViewFinishedWithIssues';
  }
}
