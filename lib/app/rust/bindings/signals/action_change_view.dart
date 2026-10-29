// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A re-dialled review's action row that is not the one answered before:
/// `was` is the action that was, `None` for a path new to the review.
@immutable
class ActionChangeView {
  const ActionChangeView({
    this.was,
  });

  static ActionChangeView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ActionChangeView(
      was: TraitHelpers.deserializeOptionActionView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ActionChangeView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ActionChangeView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final ActionView? was;

  ActionChangeView copyWith({
    ActionView? Function()? was,
  }) {
    return ActionChangeView(
      was: was == null ? this.was : was(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeOptionActionView(was, serializer);
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

    return other is ActionChangeView
      && was == other.was;
  }

  @override
  int get hashCode => was.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'was: $was'
        ')';
      return true;
    }());

    return fullString ?? 'ActionChangeView';
  }
}
