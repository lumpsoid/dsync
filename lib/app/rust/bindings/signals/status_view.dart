// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class StatusView {
  const StatusView();

  void serialize(BinarySerializer serializer);

  static StatusView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return StatusViewUnchanged.load(deserializer);
      case 1: return StatusViewCreated.load(deserializer);
      case 2: return StatusViewModified.load(deserializer);
      case 3: return StatusViewDeleted.load(deserializer);
      default: throw Exception('Unknown variant index for StatusView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static StatusView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = StatusView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class StatusViewUnchanged extends StatusView {
  const StatusViewUnchanged({
    required this.file,
    required this.byHash,
  }) : super();

  static StatusViewUnchanged load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = StatusViewUnchanged(
      file: FileView.deserialize(deserializer),
      byHash: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final FileView file;
  final bool byHash;

  StatusViewUnchanged copyWith({
    FileView? file,
    bool? byHash,
  }) {
    return StatusViewUnchanged(
      file: file ?? this.file,
      byHash: byHash ?? this.byHash,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    file.serialize(serializer);
    serializer.serializeBool(byHash);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is StatusViewUnchanged
      && file == other.file
      && byHash == other.byHash;
  }

  @override
  int get hashCode => Object.hash(
        file,
        byHash,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'file: $file, '
        'byHash: $byHash'
        ')';
      return true;
    }());

    return fullString ?? 'StatusViewUnchanged';
  }
}

@immutable
class StatusViewCreated extends StatusView {
  const StatusViewCreated({
    required this.value,
  }) : super();

  static StatusViewCreated load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = StatusViewCreated(
      value: FileView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final FileView value;

  StatusViewCreated copyWith({
    FileView? value,
  }) {
    return StatusViewCreated(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is StatusViewCreated
      && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'value: $value'
        ')';
      return true;
    }());

    return fullString ?? 'StatusViewCreated';
  }
}

@immutable
class StatusViewModified extends StatusView {
  const StatusViewModified({
    required this.value,
  }) : super();

  static StatusViewModified load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = StatusViewModified(
      value: FileView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final FileView value;

  StatusViewModified copyWith({
    FileView? value,
  }) {
    return StatusViewModified(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is StatusViewModified
      && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'value: $value'
        ')';
      return true;
    }());

    return fullString ?? 'StatusViewModified';
  }
}

@immutable
class StatusViewDeleted extends StatusView {
  const StatusViewDeleted(
  ) : super();

  static StatusViewDeleted load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = StatusViewDeleted(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is StatusViewDeleted;
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

    return fullString ?? 'StatusViewDeleted';
  }
}
