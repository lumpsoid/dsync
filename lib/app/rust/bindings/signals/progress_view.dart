// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ProgressView {
  const ProgressView({
    required this.completed,
    required this.received,
    required this.total,
  });

  static ProgressView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProgressView(
      completed: deserializer.deserializeUint64(),
      received: deserializer.deserializeUint64(),
      total: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ProgressView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ProgressView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 completed;
  final Uint64 received;
  final Uint64 total;

  ProgressView copyWith({
    Uint64? completed,
    Uint64? received,
    Uint64? total,
  }) {
    return ProgressView(
      completed: completed ?? this.completed,
      received: received ?? this.received,
      total: total ?? this.total,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(completed);
    serializer.serializeUint64(received);
    serializer.serializeUint64(total);
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

    return other is ProgressView
      && completed == other.completed
      && received == other.received
      && total == other.total;
  }

  @override
  int get hashCode => Object.hash(
        completed,
        received,
        total,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'completed: $completed, '
        'received: $received, '
        'total: $total'
        ')';
      return true;
    }());

    return fullString ?? 'ProgressView';
  }
}
