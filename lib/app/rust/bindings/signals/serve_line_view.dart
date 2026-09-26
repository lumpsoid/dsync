// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One connection event, when it happened.
@immutable
class ServeLineView {
  const ServeLineView({
    required this.atMs,
    required this.event,
  });

  static ServeLineView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeLineView(
      atMs: deserializer.deserializeInt64(),
      event: ServeEventView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ServeLineView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeLineView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int atMs;
  final ServeEventView event;

  ServeLineView copyWith({
    int? atMs,
    ServeEventView? event,
  }) {
    return ServeLineView(
      atMs: atMs ?? this.atMs,
      event: event ?? this.event,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeInt64(atMs);
    event.serialize(serializer);
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

    return other is ServeLineView
      && atMs == other.atMs
      && event == other.event;
  }

  @override
  int get hashCode => Object.hash(
        atMs,
        event,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'atMs: $atMs, '
        'event: $event'
        ')';
      return true;
    }());

    return fullString ?? 'ServeLineView';
  }
}
