// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class SummaryView {
  const SummaryView({
    required this.applied,
    required this.skipped,
    required this.conflicts,
    required this.failed,
    required this.unreadable,
  });

  static SummaryView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SummaryView(
      applied: deserializer.deserializeUint64(),
      skipped: deserializer.deserializeUint64(),
      conflicts: deserializer.deserializeUint64(),
      failed: deserializer.deserializeUint64(),
      unreadable: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SummaryView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SummaryView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 applied;
  final Uint64 skipped;
  final Uint64 conflicts;
  final Uint64 failed;
  final Uint64 unreadable;

  SummaryView copyWith({
    Uint64? applied,
    Uint64? skipped,
    Uint64? conflicts,
    Uint64? failed,
    Uint64? unreadable,
  }) {
    return SummaryView(
      applied: applied ?? this.applied,
      skipped: skipped ?? this.skipped,
      conflicts: conflicts ?? this.conflicts,
      failed: failed ?? this.failed,
      unreadable: unreadable ?? this.unreadable,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(applied);
    serializer.serializeUint64(skipped);
    serializer.serializeUint64(conflicts);
    serializer.serializeUint64(failed);
    serializer.serializeUint64(unreadable);
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

    return other is SummaryView
      && applied == other.applied
      && skipped == other.skipped
      && conflicts == other.conflicts
      && failed == other.failed
      && unreadable == other.unreadable;
  }

  @override
  int get hashCode => Object.hash(
        applied,
        skipped,
        conflicts,
        failed,
        unreadable,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'applied: $applied, '
        'skipped: $skipped, '
        'conflicts: $conflicts, '
        'failed: $failed, '
        'unreadable: $unreadable'
        ')';
      return true;
    }());

    return fullString ?? 'SummaryView';
  }
}
