// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One action's outcome; `failure` says why it did not land.
@immutable
class ResultView {
  const ResultView({
    required this.action,
    this.failure,
  });

  static ResultView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ResultView(
      action: ActionView.deserialize(deserializer),
      failure: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ResultView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ResultView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final ActionView action;
  final String? failure;

  ResultView copyWith({
    ActionView? action,
    String? Function()? failure,
  }) {
    return ResultView(
      action: action ?? this.action,
      failure: failure == null ? this.failure : failure(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    action.serialize(serializer);
    TraitHelpers.serializeOptionStr(failure, serializer);
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

    return other is ResultView
      && action == other.action
      && failure == other.failure;
  }

  @override
  int get hashCode => Object.hash(
        action,
        failure,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'action: $action, '
        'failure: $failure'
        ')';
      return true;
    }());

    return fullString ?? 'ResultView';
  }
}
