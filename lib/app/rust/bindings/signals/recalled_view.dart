// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A re-dialled review's count of its rows: how many changed since the
/// head answered them (the review shows them first) and how many kept the
/// head's earlier choice.
@immutable
class RecalledView {
  const RecalledView({
    required this.changed,
    required this.kept,
    required this.draft,
  });

  static RecalledView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RecalledView(
      changed: deserializer.deserializeUint64(),
      kept: deserializer.deserializeUint64(),
      draft: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RecalledView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RecalledView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 changed;
  final Uint64 kept;
  final bool draft;

  RecalledView copyWith({
    Uint64? changed,
    Uint64? kept,
    bool? draft,
  }) {
    return RecalledView(
      changed: changed ?? this.changed,
      kept: kept ?? this.kept,
      draft: draft ?? this.draft,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(changed);
    serializer.serializeUint64(kept);
    serializer.serializeBool(draft);
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

    return other is RecalledView
      && changed == other.changed
      && kept == other.kept
      && draft == other.draft;
  }

  @override
  int get hashCode => Object.hash(
        changed,
        kept,
        draft,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'changed: $changed, '
        'kept: $kept, '
        'draft: $draft'
        ')';
      return true;
    }());

    return fullString ?? 'RecalledView';
  }
}
