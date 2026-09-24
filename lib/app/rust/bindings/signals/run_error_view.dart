// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A run failure. `replica_busy`: SPEC §4.3's held lock, its own outcome
/// with its own remedy (wait for the other run).
@immutable
class RunErrorView {
  const RunErrorView({
    this.side,
    required this.message,
    required this.replicaBusy,
  });

  static RunErrorView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunErrorView(
      side: TraitHelpers.deserializeOptionSideView(deserializer),
      message: deserializer.deserializeString(),
      replicaBusy: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RunErrorView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunErrorView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final SideView? side;
  final String message;
  final bool replicaBusy;

  RunErrorView copyWith({
    SideView? Function()? side,
    String? message,
    bool? replicaBusy,
  }) {
    return RunErrorView(
      side: side == null ? this.side : side(),
      message: message ?? this.message,
      replicaBusy: replicaBusy ?? this.replicaBusy,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeOptionSideView(side, serializer);
    serializer.serializeString(message);
    serializer.serializeBool(replicaBusy);
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

    return other is RunErrorView
      && side == other.side
      && message == other.message
      && replicaBusy == other.replicaBusy;
  }

  @override
  int get hashCode => Object.hash(
        side,
        message,
        replicaBusy,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side, '
        'message: $message, '
        'replicaBusy: $replicaBusy'
        ')';
      return true;
    }());

    return fullString ?? 'RunErrorView';
  }
}
