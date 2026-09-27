// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One entry of a run session: its roots as typed, and how it went.
@immutable
class EntryRunView {
  const EntryRunView({
    required this.kind,
    required this.localRoot,
    required this.remoteRoot,
    required this.status,
  });

  static EntryRunView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryRunView(
      kind: RootKindViewExtension.deserialize(deserializer),
      localRoot: deserializer.deserializeString(),
      remoteRoot: deserializer.deserializeString(),
      status: EntryStatusView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static EntryRunView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EntryRunView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final RootKindView kind;
  final String localRoot;
  final String remoteRoot;
  final EntryStatusView status;

  EntryRunView copyWith({
    RootKindView? kind,
    String? localRoot,
    String? remoteRoot,
    EntryStatusView? status,
  }) {
    return EntryRunView(
      kind: kind ?? this.kind,
      localRoot: localRoot ?? this.localRoot,
      remoteRoot: remoteRoot ?? this.remoteRoot,
      status: status ?? this.status,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    kind.serialize(serializer);
    serializer.serializeString(localRoot);
    serializer.serializeString(remoteRoot);
    status.serialize(serializer);
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

    return other is EntryRunView
      && kind == other.kind
      && localRoot == other.localRoot
      && remoteRoot == other.remoteRoot
      && status == other.status;
  }

  @override
  int get hashCode => Object.hash(
        kind,
        localRoot,
        remoteRoot,
        status,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'kind: $kind, '
        'localRoot: $localRoot, '
        'remoteRoot: $remoteRoot, '
        'status: $status'
        ')';
      return true;
    }());

    return fullString ?? 'EntryRunView';
  }
}
