// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Serving, as the head shows it, whole: sent after every change.
@immutable
class ServeView {
  const ServeView({
    required this.phase,
    required this.lines,
  });

  static ServeView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeView(
      phase: ServePhaseView.deserialize(deserializer),
      lines: TraitHelpers.deserializeVectorServeLineView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ServeView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final ServePhaseView phase;
  final List<ServeLineView> lines;

  ServeView copyWith({
    ServePhaseView? phase,
    List<ServeLineView>? lines,
  }) {
    return ServeView(
      phase: phase ?? this.phase,
      lines: lines ?? this.lines,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    phase.serialize(serializer);
    TraitHelpers.serializeVectorServeLineView(lines, serializer);
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

    return other is ServeView
      && phase == other.phase
      && listEquals(lines, other.lines);
  }

  @override
  int get hashCode => Object.hash(
        phase,
        lines,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'phase: $phase, '
        'lines: $lines'
        ')';
      return true;
    }());

    return fullString ?? 'ServeView';
  }
}
