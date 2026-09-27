// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One entry of a [`ProfileView`]: a root on this device and one on the
/// profile's paired device.
@immutable
class EntryView {
  const EntryView({
    required this.entryId,
    required this.kind,
    required this.localRoot,
    required this.localRootExpanded,
    this.localRootRefusal,
    required this.remoteRoot,
  });

  static EntryView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryView(
      entryId: deserializer.deserializeString(),
      kind: RootKindViewExtension.deserialize(deserializer),
      localRoot: deserializer.deserializeString(),
      localRootExpanded: deserializer.deserializeString(),
      localRootRefusal: TraitHelpers.deserializeOptionStr(deserializer),
      remoteRoot: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static EntryView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EntryView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String entryId;
  final RootKindView kind;
  final String localRoot;
  final String localRootExpanded;
  final String? localRootRefusal;
  final String remoteRoot;

  EntryView copyWith({
    String? entryId,
    RootKindView? kind,
    String? localRoot,
    String? localRootExpanded,
    String? Function()? localRootRefusal,
    String? remoteRoot,
  }) {
    return EntryView(
      entryId: entryId ?? this.entryId,
      kind: kind ?? this.kind,
      localRoot: localRoot ?? this.localRoot,
      localRootExpanded: localRootExpanded ?? this.localRootExpanded,
      localRootRefusal: localRootRefusal == null ? this.localRootRefusal : localRootRefusal(),
      remoteRoot: remoteRoot ?? this.remoteRoot,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(entryId);
    kind.serialize(serializer);
    serializer.serializeString(localRoot);
    serializer.serializeString(localRootExpanded);
    TraitHelpers.serializeOptionStr(localRootRefusal, serializer);
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

    return other is EntryView
      && entryId == other.entryId
      && kind == other.kind
      && localRoot == other.localRoot
      && localRootExpanded == other.localRootExpanded
      && localRootRefusal == other.localRootRefusal
      && remoteRoot == other.remoteRoot;
  }

  @override
  int get hashCode => Object.hash(
        entryId,
        kind,
        localRoot,
        localRootExpanded,
        localRootRefusal,
        remoteRoot,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'entryId: $entryId, '
        'kind: $kind, '
        'localRoot: $localRoot, '
        'localRootExpanded: $localRootExpanded, '
        'localRootRefusal: $localRootRefusal, '
        'remoteRoot: $remoteRoot'
        ')';
      return true;
    }());

    return fullString ?? 'EntryView';
  }
}
