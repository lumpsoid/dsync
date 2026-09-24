// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class FilterFolderView {
  const FilterFolderView({
    this.path,
    required this.depth,
    this.excludedBy,
    required this.includedFiles,
    required this.includedBytes,
    required this.excludedFiles,
    required this.excludedBytes,
  });

  static FilterFolderView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = FilterFolderView(
      path: TraitHelpers.deserializeOptionStr(deserializer),
      depth: deserializer.deserializeUint32(),
      excludedBy: TraitHelpers.deserializeOptionStr(deserializer),
      includedFiles: deserializer.deserializeUint64(),
      includedBytes: deserializer.deserializeUint64(),
      excludedFiles: deserializer.deserializeUint64(),
      excludedBytes: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static FilterFolderView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = FilterFolderView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String? path;
  final int depth;
  final String? excludedBy;
  final Uint64 includedFiles;
  final Uint64 includedBytes;
  final Uint64 excludedFiles;
  final Uint64 excludedBytes;

  FilterFolderView copyWith({
    String? Function()? path,
    int? depth,
    String? Function()? excludedBy,
    Uint64? includedFiles,
    Uint64? includedBytes,
    Uint64? excludedFiles,
    Uint64? excludedBytes,
  }) {
    return FilterFolderView(
      path: path == null ? this.path : path(),
      depth: depth ?? this.depth,
      excludedBy: excludedBy == null ? this.excludedBy : excludedBy(),
      includedFiles: includedFiles ?? this.includedFiles,
      includedBytes: includedBytes ?? this.includedBytes,
      excludedFiles: excludedFiles ?? this.excludedFiles,
      excludedBytes: excludedBytes ?? this.excludedBytes,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeOptionStr(path, serializer);
    serializer.serializeUint32(depth);
    TraitHelpers.serializeOptionStr(excludedBy, serializer);
    serializer.serializeUint64(includedFiles);
    serializer.serializeUint64(includedBytes);
    serializer.serializeUint64(excludedFiles);
    serializer.serializeUint64(excludedBytes);
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

    return other is FilterFolderView
      && path == other.path
      && depth == other.depth
      && excludedBy == other.excludedBy
      && includedFiles == other.includedFiles
      && includedBytes == other.includedBytes
      && excludedFiles == other.excludedFiles
      && excludedBytes == other.excludedBytes;
  }

  @override
  int get hashCode => Object.hash(
        path,
        depth,
        excludedBy,
        includedFiles,
        includedBytes,
        excludedFiles,
        excludedBytes,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'depth: $depth, '
        'excludedBy: $excludedBy, '
        'includedFiles: $includedFiles, '
        'includedBytes: $includedBytes, '
        'excludedFiles: $excludedFiles, '
        'excludedBytes: $excludedBytes'
        ')';
      return true;
    }());

    return fullString ?? 'FilterFolderView';
  }
}
