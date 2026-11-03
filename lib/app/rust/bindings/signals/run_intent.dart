// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What the user did to a run. The run holds the review's choices and
/// decides what each intent means where it stands: one it cannot take -
/// a choice the row does not offer, an answer nobody asked for, an answer
/// about a plan other than the one asked about, a resume of a live run -
/// changes nothing.
///
/// Every answer to a question about a plan - the review's and SPEC §10's
/// guards' - carries `plan_id`, the plan the snapshot the head showed
/// asked about ([`crate::views::RunPhaseView`]), and the run takes it only
/// while that same plan is asked about: a tap on a plan that a resume,
/// a re-dial or the next entry has since replaced lands nowhere.
abstract class RunIntent {
  const RunIntent();

  void serialize(BinarySerializer serializer);

  static RunIntent deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return RunIntentChooseAction.load(deserializer);
      case 1: return RunIntentChooseConflict.load(deserializer);
      case 2: return RunIntentConfirm.load(deserializer);
      case 3: return RunIntentAcceptAll.load(deserializer);
      case 4: return RunIntentAnswerDeletes.load(deserializer);
      case 5: return RunIntentAnswerOverwrites.load(deserializer);
      case 6: return RunIntentStop.load(deserializer);
      case 7: return RunIntentPause.load(deserializer);
      case 8: return RunIntentResume.load(deserializer);
      case 9: return RunIntentForeground.load(deserializer);
      case 10: return RunIntentClose.load(deserializer);
      default: throw Exception('Unknown variant index for RunIntent: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static RunIntent bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunIntent.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class RunIntentChooseAction extends RunIntent {
  const RunIntentChooseAction({
    required this.planId,
    required this.index,
    required this.choice,
  }) : super();

  static RunIntentChooseAction load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentChooseAction(
      planId: deserializer.deserializeUint64(),
      index: deserializer.deserializeUint32(),
      choice: ActionChoiceViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 planId;
  final int index;
  final ActionChoiceView choice;

  RunIntentChooseAction copyWith({
    Uint64? planId,
    int? index,
    ActionChoiceView? choice,
  }) {
    return RunIntentChooseAction(
      planId: planId ?? this.planId,
      index: index ?? this.index,
      choice: choice ?? this.choice,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeUint64(planId);
    serializer.serializeUint32(index);
    choice.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentChooseAction
      && planId == other.planId
      && index == other.index
      && choice == other.choice;
  }

  @override
  int get hashCode => Object.hash(
        planId,
        index,
        choice,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'planId: $planId, '
        'index: $index, '
        'choice: $choice'
        ')';
      return true;
    }());

    return fullString ?? 'RunIntentChooseAction';
  }
}

@immutable
class RunIntentChooseConflict extends RunIntent {
  const RunIntentChooseConflict({
    required this.planId,
    required this.index,
    required this.choice,
  }) : super();

  static RunIntentChooseConflict load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentChooseConflict(
      planId: deserializer.deserializeUint64(),
      index: deserializer.deserializeUint32(),
      choice: ConflictChoiceViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 planId;
  final int index;
  final ConflictChoiceView choice;

  RunIntentChooseConflict copyWith({
    Uint64? planId,
    int? index,
    ConflictChoiceView? choice,
  }) {
    return RunIntentChooseConflict(
      planId: planId ?? this.planId,
      index: index ?? this.index,
      choice: choice ?? this.choice,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeUint64(planId);
    serializer.serializeUint32(index);
    choice.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentChooseConflict
      && planId == other.planId
      && index == other.index
      && choice == other.choice;
  }

  @override
  int get hashCode => Object.hash(
        planId,
        index,
        choice,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'planId: $planId, '
        'index: $index, '
        'choice: $choice'
        ')';
      return true;
    }());

    return fullString ?? 'RunIntentChooseConflict';
  }
}

@immutable
class RunIntentConfirm extends RunIntent {
  const RunIntentConfirm({
    required this.planId,
  }) : super();

  static RunIntentConfirm load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentConfirm(
      planId: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 planId;

  RunIntentConfirm copyWith({
    Uint64? planId,
  }) {
    return RunIntentConfirm(
      planId: planId ?? this.planId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeUint64(planId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentConfirm
      && planId == other.planId;
  }

  @override
  int get hashCode => planId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'planId: $planId'
        ')';
      return true;
    }());

    return fullString ?? 'RunIntentConfirm';
  }
}

@immutable
class RunIntentAcceptAll extends RunIntent {
  const RunIntentAcceptAll({
    required this.planId,
  }) : super();

  static RunIntentAcceptAll load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentAcceptAll(
      planId: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 planId;

  RunIntentAcceptAll copyWith({
    Uint64? planId,
  }) {
    return RunIntentAcceptAll(
      planId: planId ?? this.planId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeUint64(planId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentAcceptAll
      && planId == other.planId;
  }

  @override
  int get hashCode => planId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'planId: $planId'
        ')';
      return true;
    }());

    return fullString ?? 'RunIntentAcceptAll';
  }
}

@immutable
class RunIntentAnswerDeletes extends RunIntent {
  const RunIntentAnswerDeletes({
    required this.planId,
    required this.proceed,
  }) : super();

  static RunIntentAnswerDeletes load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentAnswerDeletes(
      planId: deserializer.deserializeUint64(),
      proceed: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 planId;
  final bool proceed;

  RunIntentAnswerDeletes copyWith({
    Uint64? planId,
    bool? proceed,
  }) {
    return RunIntentAnswerDeletes(
      planId: planId ?? this.planId,
      proceed: proceed ?? this.proceed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.serializeUint64(planId);
    serializer.serializeBool(proceed);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentAnswerDeletes
      && planId == other.planId
      && proceed == other.proceed;
  }

  @override
  int get hashCode => Object.hash(
        planId,
        proceed,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'planId: $planId, '
        'proceed: $proceed'
        ')';
      return true;
    }());

    return fullString ?? 'RunIntentAnswerDeletes';
  }
}

@immutable
class RunIntentAnswerOverwrites extends RunIntent {
  const RunIntentAnswerOverwrites({
    required this.planId,
    required this.proceed,
  }) : super();

  static RunIntentAnswerOverwrites load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentAnswerOverwrites(
      planId: deserializer.deserializeUint64(),
      proceed: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 planId;
  final bool proceed;

  RunIntentAnswerOverwrites copyWith({
    Uint64? planId,
    bool? proceed,
  }) {
    return RunIntentAnswerOverwrites(
      planId: planId ?? this.planId,
      proceed: proceed ?? this.proceed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.serializeUint64(planId);
    serializer.serializeBool(proceed);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentAnswerOverwrites
      && planId == other.planId
      && proceed == other.proceed;
  }

  @override
  int get hashCode => Object.hash(
        planId,
        proceed,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'planId: $planId, '
        'proceed: $proceed'
        ')';
      return true;
    }());

    return fullString ?? 'RunIntentAnswerOverwrites';
  }
}

@immutable
class RunIntentStop extends RunIntent {
  const RunIntentStop(
  ) : super();

  static RunIntentStop load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentStop(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentStop;
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

    return fullString ?? 'RunIntentStop';
  }
}

@immutable
class RunIntentPause extends RunIntent {
  const RunIntentPause(
  ) : super();

  static RunIntentPause load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentPause(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentPause;
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

    return fullString ?? 'RunIntentPause';
  }
}

@immutable
class RunIntentResume extends RunIntent {
  const RunIntentResume(
  ) : super();

  static RunIntentResume load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentResume(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentResume;
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

    return fullString ?? 'RunIntentResume';
  }
}

@immutable
class RunIntentForeground extends RunIntent {
  const RunIntentForeground(
  ) : super();

  static RunIntentForeground load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentForeground(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(9);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentForeground;
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

    return fullString ?? 'RunIntentForeground';
  }
}

@immutable
class RunIntentClose extends RunIntent {
  const RunIntentClose(
  ) : super();

  static RunIntentClose load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentClose(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentClose;
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

    return fullString ?? 'RunIntentClose';
  }
}
