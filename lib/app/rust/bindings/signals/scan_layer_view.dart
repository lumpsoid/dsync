// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ScanLayerView {
  const ScanLayerView({
    required this.label,
    required this.elapsedMicros,
    required this.files,
    this.directories,
    required this.bytes,
    required this.microsPerFile,
  });

  static ScanLayerView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ScanLayerView(
      label: deserializer.deserializeString(),
      elapsedMicros: deserializer.deserializeUint64(),
      files: deserializer.deserializeUint64(),
      directories: TraitHelpers.deserializeOptionU64(deserializer),
      bytes: deserializer.deserializeUint64(),
      microsPerFile: deserializer.deserializeFloat64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ScanLayerView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ScanLayerView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String label;
  final Uint64 elapsedMicros;
  final Uint64 files;
  final Uint64? directories;
  final Uint64 bytes;
  final double microsPerFile;

  ScanLayerView copyWith({
    String? label,
    Uint64? elapsedMicros,
    Uint64? files,
    Uint64? Function()? directories,
    Uint64? bytes,
    double? microsPerFile,
  }) {
    return ScanLayerView(
      label: label ?? this.label,
      elapsedMicros: elapsedMicros ?? this.elapsedMicros,
      files: files ?? this.files,
      directories: directories == null ? this.directories : directories(),
      bytes: bytes ?? this.bytes,
      microsPerFile: microsPerFile ?? this.microsPerFile,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(label);
    serializer.serializeUint64(elapsedMicros);
    serializer.serializeUint64(files);
    TraitHelpers.serializeOptionU64(directories, serializer);
    serializer.serializeUint64(bytes);
    serializer.serializeFloat64(microsPerFile);
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

    return other is ScanLayerView
      && label == other.label
      && elapsedMicros == other.elapsedMicros
      && files == other.files
      && directories == other.directories
      && bytes == other.bytes
      && microsPerFile == other.microsPerFile;
  }

  @override
  int get hashCode => Object.hash(
        label,
        elapsedMicros,
        files,
        directories,
        bytes,
        microsPerFile,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'label: $label, '
        'elapsedMicros: $elapsedMicros, '
        'files: $files, '
        'directories: $directories, '
        'bytes: $bytes, '
        'microsPerFile: $microsPerFile'
        ')';
      return true;
    }());

    return fullString ?? 'ScanLayerView';
  }
}
