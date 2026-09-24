// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class FileView {
  const FileView({
    required this.size,
    required this.mtimeUs,
  });

  static FileView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = FileView(
      size: deserializer.deserializeUint64(),
      mtimeUs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static FileView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = FileView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 size;
  final int mtimeUs;

  FileView copyWith({
    Uint64? size,
    int? mtimeUs,
  }) {
    return FileView(
      size: size ?? this.size,
      mtimeUs: mtimeUs ?? this.mtimeUs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(size);
    serializer.serializeInt64(mtimeUs);
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

    return other is FileView
      && size == other.size
      && mtimeUs == other.mtimeUs;
  }

  @override
  int get hashCode => Object.hash(
        size,
        mtimeUs,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'size: $size, '
        'mtimeUs: $mtimeUs'
        ')';
      return true;
    }());

    return fullString ?? 'FileView';
  }
}
