// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// How a run's session ended.
abstract class RunEndView {
  const RunEndView();

  void serialize(BinarySerializer serializer);

  static RunEndView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return RunEndViewRan.load(deserializer);
      case 1: return RunEndViewNotConnected.load(deserializer);
      case 2: return RunEndViewStoppedConnecting.load(deserializer);
      default: throw Exception('Unknown variant index for RunEndView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static RunEndView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunEndView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class RunEndViewRan extends RunEndView {
  const RunEndViewRan({
    this.summary,
    required this.errored,
    this.stopped,
    required this.timings,
  }) : super();

  static RunEndViewRan load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunEndViewRan(
      summary: TraitHelpers.deserializeOptionSummaryView(deserializer),
      errored: deserializer.deserializeBool(),
      stopped: TraitHelpers.deserializeOptionStoppedView(deserializer),
      timings: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SummaryView? summary;
  final bool errored;
  final StoppedView? stopped;
  final String timings;

  RunEndViewRan copyWith({
    SummaryView? Function()? summary,
    bool? errored,
    StoppedView? Function()? stopped,
    String? timings,
  }) {
    return RunEndViewRan(
      summary: summary == null ? this.summary : summary(),
      errored: errored ?? this.errored,
      stopped: stopped == null ? this.stopped : stopped(),
      timings: timings ?? this.timings,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    TraitHelpers.serializeOptionSummaryView(summary, serializer);
    serializer.serializeBool(errored);
    TraitHelpers.serializeOptionStoppedView(stopped, serializer);
    serializer.serializeString(timings);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunEndViewRan
      && summary == other.summary
      && errored == other.errored
      && stopped == other.stopped
      && timings == other.timings;
  }

  @override
  int get hashCode => Object.hash(
        summary,
        errored,
        stopped,
        timings,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'summary: $summary, '
        'errored: $errored, '
        'stopped: $stopped, '
        'timings: $timings'
        ')';
      return true;
    }());

    return fullString ?? 'RunEndViewRan';
  }
}

@immutable
class RunEndViewNotConnected extends RunEndView {
  const RunEndViewNotConnected({
    required this.message,
  }) : super();

  static RunEndViewNotConnected load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunEndViewNotConnected(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  RunEndViewNotConnected copyWith({
    String? message,
  }) {
    return RunEndViewNotConnected(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunEndViewNotConnected
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

    return fullString ?? 'RunEndViewNotConnected';
  }
}

@immutable
class RunEndViewStoppedConnecting extends RunEndView {
  const RunEndViewStoppedConnecting(
  ) : super();

  static RunEndViewStoppedConnecting load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunEndViewStoppedConnecting(
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

    return other is RunEndViewStoppedConnecting;
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

    return fullString ?? 'RunEndViewStoppedConnecting';
  }
}
