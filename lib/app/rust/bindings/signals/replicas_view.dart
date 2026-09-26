// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ReplicasView {
  const ReplicasView({
    required this.a,
    required this.b,
    required this.history,
  });

  static ReplicasView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplicasView(
      a: ReplicaInfoView.deserialize(deserializer),
      b: ReplicaInfoView.deserialize(deserializer),
      history: HistoryView.deserialize(deserializer),
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
  final HistoryView history;

  ReplicasView copyWith({
    ReplicaInfoView? a,
    ReplicaInfoView? b,
    HistoryView? history,
  }) {
    return ReplicasView(
      a: a ?? this.a,
      b: b ?? this.b,
      history: history ?? this.history,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    a.serialize(serializer);
    b.serialize(serializer);
    history.serialize(serializer);
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
      && b == other.b
      && history == other.history;
  }

  @override
  int get hashCode => Object.hash(
        a,
        b,
        history,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'a: $a, '
        'b: $b, '
        'history: $history'
        ')';
      return true;
    }());

    return fullString ?? 'ReplicasView';
  }
}
