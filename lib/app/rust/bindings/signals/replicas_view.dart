// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ReplicasView {
  const ReplicasView({
    required this.a,
    required this.b,
  });

  static ReplicasView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplicasView(
      a: ReplicaInfoView.deserialize(deserializer),
      b: ReplicaInfoView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ReplicasView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ReplicasView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final ReplicaInfoView a;
  final ReplicaInfoView b;

  ReplicasView copyWith({
    ReplicaInfoView? a,
    ReplicaInfoView? b,
  }) {
    return ReplicasView(
      a: a ?? this.a,
      b: b ?? this.b,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    a.serialize(serializer);
    b.serialize(serializer);
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

    return other is ReplicasView
      && a == other.a
      && b == other.b;
  }

  @override
  int get hashCode => Object.hash(
        a,
        b,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'a: $a, '
        'b: $b'
        ')';
      return true;
    }());

    return fullString ?? 'ReplicasView';
  }
}
