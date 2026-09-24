// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One stage of writing a file (mkdir, probe, create, open, wait, write,
/// mtime, close, rename), over the whole transfer.
@immutable
class StageTiming {
  const StageTiming({
    required this.name,
    required this.count,
    required this.meanMs,
    required this.totalSeconds,
  });

  static StageTiming deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = StageTiming(
      name: deserializer.deserializeString(),
      count: deserializer.deserializeUint64(),
      meanMs: deserializer.deserializeFloat64(),
      totalSeconds: deserializer.deserializeFloat64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static StageTiming bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = StageTiming.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String name;
  final Uint64 count;
  final double meanMs;
  final double totalSeconds;

  StageTiming copyWith({
    String? name,
    Uint64? count,
    double? meanMs,
    double? totalSeconds,
  }) {
    return StageTiming(
      name: name ?? this.name,
      count: count ?? this.count,
      meanMs: meanMs ?? this.meanMs,
      totalSeconds: totalSeconds ?? this.totalSeconds,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(name);
    serializer.serializeUint64(count);
    serializer.serializeFloat64(meanMs);
    serializer.serializeFloat64(totalSeconds);
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

    return other is StageTiming
      && name == other.name
      && count == other.count
      && meanMs == other.meanMs
      && totalSeconds == other.totalSeconds;
  }

  @override
  int get hashCode => Object.hash(
        name,
        count,
        meanMs,
        totalSeconds,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'name: $name, '
        'count: $count, '
        'meanMs: $meanMs, '
        'totalSeconds: $totalSeconds'
        ')';
      return true;
    }());

    return fullString ?? 'StageTiming';
  }
}
