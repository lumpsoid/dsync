// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class RuleCountView {
  const RuleCountView({
    required this.pattern,
    required this.files,
  });

  static RuleCountView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RuleCountView(
      pattern: deserializer.deserializeString(),
      files: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static RuleCountView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RuleCountView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String pattern;
  final Uint64 files;

  RuleCountView copyWith({
    String? pattern,
    Uint64? files,
  }) {
    return RuleCountView(
      pattern: pattern ?? this.pattern,
      files: files ?? this.files,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(pattern);
    serializer.serializeUint64(files);
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

    return other is RuleCountView
      && pattern == other.pattern
      && files == other.files;
  }

  @override
  int get hashCode => Object.hash(
        pattern,
        files,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'pattern: $pattern, '
        'files: $files'
        ')';
      return true;
    }());

    return fullString ?? 'RuleCountView';
  }
}
