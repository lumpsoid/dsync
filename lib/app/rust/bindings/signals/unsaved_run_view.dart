// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class UnsavedRunView {
  const UnsavedRunView({
    required this.entryId,
    this.pair,
    required this.lastRun,
  });

  static UnsavedRunView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = UnsavedRunView(
      entryId: deserializer.deserializeString(),
      pair: TraitHelpers.deserializeOptionOtherEntryView(deserializer),
      lastRun: LastRunViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static UnsavedRunView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = UnsavedRunView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String entryId;
  final OtherEntryView? pair;
  final LastRunView lastRun;

  UnsavedRunView copyWith({
    String? entryId,
    OtherEntryView? Function()? pair,
    LastRunView? lastRun,
  }) {
    return UnsavedRunView(
      entryId: entryId ?? this.entryId,
      pair: pair == null ? this.pair : pair(),
      lastRun: lastRun ?? this.lastRun,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(entryId);
    TraitHelpers.serializeOptionOtherEntryView(pair, serializer);
    lastRun.serialize(serializer);
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

    return other is UnsavedRunView
      && entryId == other.entryId
      && pair == other.pair
      && lastRun == other.lastRun;
  }

  @override
  int get hashCode => Object.hash(
        entryId,
        pair,
        lastRun,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'entryId: $entryId, '
        'pair: $pair, '
        'lastRun: $lastRun'
        ')';
      return true;
    }());

    return fullString ?? 'UnsavedRunView';
  }
}
