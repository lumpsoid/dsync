// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A planned action and, when it can be put the other way, the bytes that
/// reversal would copy (`None`: no reverse is offered).
@immutable
class ProposalView {
  const ProposalView({
    required this.action,
    this.reverseBytes,
  });

  static ProposalView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProposalView(
      action: ActionView.deserialize(deserializer),
      reverseBytes: TraitHelpers.deserializeOptionU64(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ProposalView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ProposalView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final ActionView action;
  final Uint64? reverseBytes;

  ProposalView copyWith({
    ActionView? action,
    Uint64? Function()? reverseBytes,
  }) {
    return ProposalView(
      action: action ?? this.action,
      reverseBytes: reverseBytes == null ? this.reverseBytes : reverseBytes(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    action.serialize(serializer);
    TraitHelpers.serializeOptionU64(reverseBytes, serializer);
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

    return other is ProposalView
      && action == other.action
      && reverseBytes == other.reverseBytes;
  }

  @override
  int get hashCode => Object.hash(
        action,
        reverseBytes,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'action: $action, '
        'reverseBytes: $reverseBytes'
        ')';
      return true;
    }());

    return fullString ?? 'ProposalView';
  }
}
