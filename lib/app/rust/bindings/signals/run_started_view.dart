// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A run that started: its archive id and its two sides as typed.
@immutable
class RunStartedView {
  const RunStartedView({
    required this.profileId,
    required this.a,
    required this.b,
  });

  static RunStartedView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunStartedView(
      profileId: deserializer.deserializeString(),
      a: deserializer.deserializeString(),
      b: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RunStartedView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunStartedView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String profileId;
  final String a;
  final String b;

  RunStartedView copyWith({
    String? profileId,
    String? a,
    String? b,
  }) {
    return RunStartedView(
      profileId: profileId ?? this.profileId,
      a: a ?? this.a,
      b: b ?? this.b,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(profileId);
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

    return other is RunStartedView
      && profileId == other.profileId
      && a == other.a
      && b == other.b;
  }

  @override
  int get hashCode => Object.hash(
        profileId,
        a,
        b,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'profileId: $profileId, '
        'a: $a, '
        'b: $b'
        ')';
      return true;
    }());

    return fullString ?? 'RunStartedView';
  }
}
