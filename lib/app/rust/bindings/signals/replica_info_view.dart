// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ReplicaInfoView {
  const ReplicaInfoView({
    this.lastCommitMs,
    this.archivePath,
    this.missingRoot,
  });

  static ReplicaInfoView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplicaInfoView(
      lastCommitMs: TraitHelpers.deserializeOptionI64(deserializer),
      archivePath: TraitHelpers.deserializeOptionStr(deserializer),
      missingRoot: TraitHelpers.deserializeOptionMissingRootView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ReplicaInfoView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ReplicaInfoView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int? lastCommitMs;
  final String? archivePath;
  final MissingRootView? missingRoot;

  ReplicaInfoView copyWith({
    int? Function()? lastCommitMs,
    String? Function()? archivePath,
    MissingRootView? Function()? missingRoot,
  }) {
    return ReplicaInfoView(
      lastCommitMs: lastCommitMs == null ? this.lastCommitMs : lastCommitMs(),
      archivePath: archivePath == null ? this.archivePath : archivePath(),
      missingRoot: missingRoot == null ? this.missingRoot : missingRoot(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeOptionI64(lastCommitMs, serializer);
    TraitHelpers.serializeOptionStr(archivePath, serializer);
    TraitHelpers.serializeOptionMissingRootView(missingRoot, serializer);
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

    return other is ReplicaInfoView
      && lastCommitMs == other.lastCommitMs
      && archivePath == other.archivePath
      && missingRoot == other.missingRoot;
  }

  @override
  int get hashCode => Object.hash(
        lastCommitMs,
        archivePath,
        missingRoot,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'lastCommitMs: $lastCommitMs, '
        'archivePath: $archivePath, '
        'missingRoot: $missingRoot'
        ')';
      return true;
    }());

    return fullString ?? 'ReplicaInfoView';
  }
}
