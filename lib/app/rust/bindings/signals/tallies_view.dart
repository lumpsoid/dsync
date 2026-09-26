// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class TalliesView {
  const TalliesView({
    required this.a,
    required this.b,
  });

  static TalliesView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TalliesView(
      a: TallyView.deserialize(deserializer),
      b: TallyView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TalliesView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TalliesView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final TallyView a;
  final TallyView b;

  TalliesView copyWith({
    TallyView? a,
    TallyView? b,
  }) {
    return TalliesView(
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

    return other is TalliesView
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

    return fullString ?? 'TalliesView';
  }
}
