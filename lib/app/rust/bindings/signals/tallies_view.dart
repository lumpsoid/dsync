// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Both scans' counts, and what they come to across the two sides.
@immutable
class TalliesView {
  const TalliesView({
    required this.a,
    required this.b,
    required this.checked,
    required this.changed,
  });

  static TalliesView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TalliesView(
      a: TallyView.deserialize(deserializer),
      b: TallyView.deserialize(deserializer),
      checked: deserializer.deserializeUint64(),
      changed: deserializer.deserializeUint64(),
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
  final Uint64 checked;
  final Uint64 changed;

  TalliesView copyWith({
    TallyView? a,
    TallyView? b,
    Uint64? checked,
    Uint64? changed,
  }) {
    return TalliesView(
      a: a ?? this.a,
      b: b ?? this.b,
      checked: checked ?? this.checked,
      changed: changed ?? this.changed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    a.serialize(serializer);
    b.serialize(serializer);
    serializer.serializeUint64(checked);
    serializer.serializeUint64(changed);
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
      && b == other.b
      && checked == other.checked
      && changed == other.changed;
  }

  @override
  int get hashCode => Object.hash(
        a,
        b,
        checked,
        changed,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'a: $a, '
        'b: $b, '
        'checked: $checked, '
        'changed: $changed'
        ')';
      return true;
    }());

    return fullString ?? 'TalliesView';
  }
}
