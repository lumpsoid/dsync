// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class EntryKindView {
  const EntryKindView();

  void serialize(BinarySerializer serializer);

  static EntryKindView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return EntryKindViewFile.load(deserializer);
      case 1: return EntryKindViewFolder.load(deserializer);
      case 2: return EntryKindViewOther.load(deserializer);
      default: throw Exception('Unknown variant index for EntryKindView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static EntryKindView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EntryKindView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class EntryKindViewFile extends EntryKindView {
  const EntryKindViewFile({
    required this.size,
  }) : super();

  static EntryKindViewFile load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryKindViewFile(
      size: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 size;

  EntryKindViewFile copyWith({
    Uint64? size,
  }) {
    return EntryKindViewFile(
      size: size ?? this.size,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeUint64(size);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EntryKindViewFile
      && size == other.size;
  }

  @override
  int get hashCode => size.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'size: $size'
        ')';
      return true;
    }());

    return fullString ?? 'EntryKindViewFile';
  }
}

@immutable
class EntryKindViewFolder extends EntryKindView {
  const EntryKindViewFolder(
  ) : super();

  static EntryKindViewFolder load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryKindViewFolder(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EntryKindViewFolder;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'EntryKindViewFolder';
  }
}

@immutable
class EntryKindViewOther extends EntryKindView {
  const EntryKindViewOther(
  ) : super();

  static EntryKindViewOther load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryKindViewOther(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EntryKindViewOther;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'EntryKindViewOther';
  }
}
