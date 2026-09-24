// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class MissingRootView {
  const MissingRootView({
    required this.rootPath,
    required this.archivedFiles,
  });

  static MissingRootView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = MissingRootView(
      rootPath: deserializer.deserializeString(),
      archivedFiles: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static MissingRootView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = MissingRootView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String rootPath;
  final Uint64 archivedFiles;

  MissingRootView copyWith({
    String? rootPath,
    Uint64? archivedFiles,
  }) {
    return MissingRootView(
      rootPath: rootPath ?? this.rootPath,
      archivedFiles: archivedFiles ?? this.archivedFiles,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(rootPath);
    serializer.serializeUint64(archivedFiles);
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

    return other is MissingRootView
      && rootPath == other.rootPath
      && archivedFiles == other.archivedFiles;
  }

  @override
  int get hashCode => Object.hash(
        rootPath,
        archivedFiles,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'rootPath: $rootPath, '
        'archivedFiles: $archivedFiles'
        ')';
      return true;
    }());

    return fullString ?? 'MissingRootView';
  }
}
