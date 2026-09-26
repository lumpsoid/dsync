// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The bytes the plan's copies write onto each side.
@immutable
class PlanSummaryView {
  const PlanSummaryView({
    required this.bytesToA,
    required this.bytesToB,
  });

  static PlanSummaryView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PlanSummaryView(
      bytesToA: deserializer.deserializeUint64(),
      bytesToB: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static PlanSummaryView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PlanSummaryView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 bytesToA;
  final Uint64 bytesToB;

  PlanSummaryView copyWith({
    Uint64? bytesToA,
    Uint64? bytesToB,
  }) {
    return PlanSummaryView(
      bytesToA: bytesToA ?? this.bytesToA,
      bytesToB: bytesToB ?? this.bytesToB,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(bytesToA);
    serializer.serializeUint64(bytesToB);
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

    return other is PlanSummaryView
      && bytesToA == other.bytesToA
      && bytesToB == other.bytesToB;
  }

  @override
  int get hashCode => Object.hash(
        bytesToA,
        bytesToB,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'bytesToA: $bytesToA, '
        'bytesToB: $bytesToB'
        ')';
      return true;
    }());

    return fullString ?? 'PlanSummaryView';
  }
}
