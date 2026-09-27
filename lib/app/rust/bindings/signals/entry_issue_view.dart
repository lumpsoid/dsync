// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// An entry that did not sync, by its place in the session's entries.
@immutable
class EntryIssueView {
  const EntryIssueView({
    required this.index,
    required this.reason,
  });

  static EntryIssueView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryIssueView(
      index: deserializer.deserializeUint32(),
      reason: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static EntryIssueView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EntryIssueView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int index;
  final String reason;

  EntryIssueView copyWith({
    int? index,
    String? reason,
  }) {
    return EntryIssueView(
      index: index ?? this.index,
      reason: reason ?? this.reason,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(index);
    serializer.serializeString(reason);
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

    return other is EntryIssueView
      && index == other.index
      && reason == other.reason;
  }

  @override
  int get hashCode => Object.hash(
        index,
        reason,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'index: $index, '
        'reason: $reason'
        ')';
      return true;
    }());

    return fullString ?? 'EntryIssueView';
  }
}
