// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One entry of a [`ProfileDraft`]: two folders, or one file each.
@immutable
class EntryDraft {
  const EntryDraft({
    required this.kind,
    required this.localRoot,
    required this.remoteRoot,
  });

  static EntryDraft deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryDraft(
      kind: RootKindViewExtension.deserialize(deserializer),
      localRoot: deserializer.deserializeString(),
      remoteRoot: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static EntryDraft bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EntryDraft.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final RootKindView kind;
  final String localRoot;
  final String remoteRoot;

  EntryDraft copyWith({
    RootKindView? kind,
    String? localRoot,
    String? remoteRoot,
  }) {
    return EntryDraft(
      kind: kind ?? this.kind,
      localRoot: localRoot ?? this.localRoot,
      remoteRoot: remoteRoot ?? this.remoteRoot,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    kind.serialize(serializer);
    serializer.serializeString(localRoot);
    serializer.serializeString(remoteRoot);
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

    return other is EntryDraft
      && kind == other.kind
      && localRoot == other.localRoot
      && remoteRoot == other.remoteRoot;
  }

  @override
  int get hashCode => Object.hash(
        kind,
        localRoot,
        remoteRoot,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'kind: $kind, '
        'localRoot: $localRoot, '
        'remoteRoot: $remoteRoot'
        ')';
      return true;
    }());

    return fullString ?? 'EntryDraft';
  }
}
