// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One entry of an [`ProfileEntry::Other`] profile, its sides as typed.
@immutable
class OtherEntryView {
  const OtherEntryView({
    required this.a,
    required this.b,
  });

  static OtherEntryView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OtherEntryView(
      a: deserializer.deserializeString(),
      b: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static OtherEntryView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = OtherEntryView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String a;
  final String b;

  OtherEntryView copyWith({
    String? a,
    String? b,
  }) {
    return OtherEntryView(
      a: a ?? this.a,
      b: b ?? this.b,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(a);
    serializer.serializeString(b);
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

    return other is OtherEntryView
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

    return fullString ?? 'OtherEntryView';
  }
}
