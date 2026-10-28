// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class SpanView {
  const SpanView({
    required this.text,
    required this.emphasized,
  });

  static SpanView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SpanView(
      text: deserializer.deserializeString(),
      emphasized: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SpanView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SpanView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String text;
  final bool emphasized;

  SpanView copyWith({
    String? text,
    bool? emphasized,
  }) {
    return SpanView(
      text: text ?? this.text,
      emphasized: emphasized ?? this.emphasized,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(text);
    serializer.serializeBool(emphasized);
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

    return other is SpanView
      && text == other.text
      && emphasized == other.emphasized;
  }

  @override
  int get hashCode => Object.hash(
        text,
        emphasized,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'text: $text, '
        'emphasized: $emphasized'
        ')';
      return true;
    }());

    return fullString ?? 'SpanView';
  }
}
