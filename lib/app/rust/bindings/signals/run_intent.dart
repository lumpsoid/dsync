// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What the user did to a run. The run holds the review's choices and
/// decides what each intent means where it stands: one it cannot take -
/// a choice the row does not offer, an answer nobody asked for, a resume
/// of a live run - changes nothing.
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
    required this.index,
    required this.choice,
  }) : super();

  static RunIntentChooseAction load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentChooseAction(
      index: deserializer.deserializeUint32(),
      choice: ActionChoiceViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int index;
  final ActionChoiceView choice;

  RunIntentChooseAction copyWith({
    int? index,
    ActionChoiceView? choice,
  }) {
    return RunIntentChooseAction(
      index: index ?? this.index,
      choice: choice ?? this.choice,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeUint32(index);
    choice.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentChooseAction
      && index == other.index
      && choice == other.choice;
  }

  @override
  int get hashCode => Object.hash(
        index,
        choice,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
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
    required this.index,
    required this.choice,
  }) : super();

  static RunIntentChooseConflict load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentChooseConflict(
      index: deserializer.deserializeUint32(),
      choice: ConflictChoiceViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int index;
  final ConflictChoiceView choice;

  RunIntentChooseConflict copyWith({
    int? index,
    ConflictChoiceView? choice,
  }) {
    return RunIntentChooseConflict(
      index: index ?? this.index,
      choice: choice ?? this.choice,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeUint32(index);
    choice.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentChooseConflict
      && index == other.index
      && choice == other.choice;
  }

  @override
  int get hashCode => Object.hash(
        index,
        choice,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
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
  const RunIntentConfirm(
  ) : super();

  static RunIntentConfirm load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentConfirm(
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

    return other is RunIntentConfirm;
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

    return fullString ?? 'RunIntentConfirm';
  }
}

@immutable
class RunIntentAcceptAll extends RunIntent {
  const RunIntentAcceptAll(
  ) : super();

  static RunIntentAcceptAll load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentAcceptAll(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentAcceptAll;
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

    return fullString ?? 'RunIntentAcceptAll';
  }
}

@immutable
class RunIntentAnswerDeletes extends RunIntent {
  const RunIntentAnswerDeletes({
    required this.proceed,
  }) : super();

  static RunIntentAnswerDeletes load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentAnswerDeletes(
      proceed: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final bool proceed;

  RunIntentAnswerDeletes copyWith({
    bool? proceed,
  }) {
    return RunIntentAnswerDeletes(
      proceed: proceed ?? this.proceed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.serializeBool(proceed);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentAnswerDeletes
      && proceed == other.proceed;
  }

  @override
  int get hashCode => proceed.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
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
    required this.proceed,
  }) : super();

  static RunIntentAnswerOverwrites load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunIntentAnswerOverwrites(
      proceed: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final bool proceed;

  RunIntentAnswerOverwrites copyWith({
    bool? proceed,
  }) {
    return RunIntentAnswerOverwrites(
      proceed: proceed ?? this.proceed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.serializeBool(proceed);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunIntentAnswerOverwrites
      && proceed == other.proceed;
  }

  @override
  int get hashCode => proceed.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
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
