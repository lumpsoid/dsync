// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A re-dialled review's conflict that is not the one answered before:
/// `was` is the conflict that was, `None` for a path new to the review.
@immutable
class ConflictChangeView {
  const ConflictChangeView({
    this.was,
  });

  static ConflictChangeView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictChangeView(
      was: TraitHelpers.deserializeOptionConflictView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ConflictChangeView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ConflictChangeView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final ConflictView? was;

  ConflictChangeView copyWith({
    ConflictView? Function()? was,
  }) {
    return ConflictChangeView(
      was: was == null ? this.was : was(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeOptionConflictView(was, serializer);
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

    return other is ConflictChangeView
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

    return fullString ?? 'ConflictChangeView';
  }
}
