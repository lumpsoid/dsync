// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ArchiveView {
  const ArchiveView({
    required this.logPath,
    required this.profileId,
    required this.side,
    this.rootPath,
    required this.sizeBytes,
    required this.lastModifiedMs,
  });

  static ArchiveView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ArchiveView(
      logPath: deserializer.deserializeString(),
      profileId: deserializer.deserializeString(),
      side: SideViewExtension.deserialize(deserializer),
      rootPath: TraitHelpers.deserializeOptionStr(deserializer),
      sizeBytes: deserializer.deserializeUint64(),
      lastModifiedMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ArchiveView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ArchiveView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String logPath;
  final String profileId;
  final SideView side;
  final String? rootPath;
  final Uint64 sizeBytes;
  final int lastModifiedMs;

  ArchiveView copyWith({
    String? logPath,
    String? profileId,
    SideView? side,
    String? Function()? rootPath,
    Uint64? sizeBytes,
    int? lastModifiedMs,
  }) {
    return ArchiveView(
      logPath: logPath ?? this.logPath,
      profileId: profileId ?? this.profileId,
      side: side ?? this.side,
      rootPath: rootPath == null ? this.rootPath : rootPath(),
      sizeBytes: sizeBytes ?? this.sizeBytes,
      lastModifiedMs: lastModifiedMs ?? this.lastModifiedMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(logPath);
    serializer.serializeString(profileId);
    side.serialize(serializer);
    TraitHelpers.serializeOptionStr(rootPath, serializer);
    serializer.serializeUint64(sizeBytes);
    serializer.serializeInt64(lastModifiedMs);
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

    return other is ArchiveView
      && logPath == other.logPath
      && profileId == other.profileId
      && side == other.side
      && rootPath == other.rootPath
      && sizeBytes == other.sizeBytes
      && lastModifiedMs == other.lastModifiedMs;
  }

  @override
  int get hashCode => Object.hash(
        logPath,
        profileId,
        side,
        rootPath,
        sizeBytes,
        lastModifiedMs,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'logPath: $logPath, '
        'profileId: $profileId, '
        'side: $side, '
        'rootPath: $rootPath, '
        'sizeBytes: $sizeBytes, '
        'lastModifiedMs: $lastModifiedMs'
        ')';
      return true;
    }());

    return fullString ?? 'ArchiveView';
  }
}
