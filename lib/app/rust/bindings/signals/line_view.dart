// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class LineView {
  const LineView({
    required this.spans,
  });

  static LineView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = LineView(
      spans: TraitHelpers.deserializeVectorSpanView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static LineView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = LineView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final List<SpanView> spans;

  LineView copyWith({
    List<SpanView>? spans,
  }) {
    return LineView(
      spans: spans ?? this.spans,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeVectorSpanView(spans, serializer);
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

    return other is LineView
      && listEquals(spans, other.spans);
  }

  @override
  int get hashCode => spans.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'spans: $spans'
        ')';
      return true;
    }());

    return fullString ?? 'LineView';
  }
}
