// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class EnrolmentUpdateBody {
  const EnrolmentUpdateBody();

  void serialize(BinarySerializer serializer);

  static EnrolmentUpdateBody deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return EnrolmentUpdateBodyRefused.load(deserializer);
      case 1: return EnrolmentUpdateBodyAwaiting.load(deserializer);
      case 2: return EnrolmentUpdateBodyEnded.load(deserializer);
      default: throw Exception('Unknown variant index for EnrolmentUpdateBody: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static EnrolmentUpdateBody bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EnrolmentUpdateBody.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class EnrolmentUpdateBodyRefused extends EnrolmentUpdateBody {
  const EnrolmentUpdateBodyRefused({
    required this.from,
    required this.message,
  }) : super();

  static EnrolmentUpdateBodyRefused load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentUpdateBodyRefused(
      from: deserializer.deserializeString(),
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String from;
  final String message;

  EnrolmentUpdateBodyRefused copyWith({
    String? from,
    String? message,
  }) {
    return EnrolmentUpdateBodyRefused(
      from: from ?? this.from,
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(from);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentUpdateBodyRefused
      && from == other.from
      && message == other.message;
  }

  @override
  int get hashCode => Object.hash(
        from,
        message,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'from: $from, '
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'EnrolmentUpdateBodyRefused';
  }
}

@immutable
class EnrolmentUpdateBodyAwaiting extends EnrolmentUpdateBody {
  const EnrolmentUpdateBodyAwaiting({
    required this.from,
    required this.deviceId,
    required this.name,
  }) : super();

  static EnrolmentUpdateBodyAwaiting load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentUpdateBodyAwaiting(
      from: deserializer.deserializeString(),
      deviceId: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String from;
  final String deviceId;
  final String name;

  EnrolmentUpdateBodyAwaiting copyWith({
    String? from,
    String? deviceId,
    String? name,
  }) {
    return EnrolmentUpdateBodyAwaiting(
      from: from ?? this.from,
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(from);
    serializer.serializeString(deviceId);
    serializer.serializeString(name);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentUpdateBodyAwaiting
      && from == other.from
      && deviceId == other.deviceId
      && name == other.name;
  }

  @override
  int get hashCode => Object.hash(
        from,
        deviceId,
        name,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'from: $from, '
        'deviceId: $deviceId, '
        'name: $name'
        ')';
      return true;
    }());

    return fullString ?? 'EnrolmentUpdateBodyAwaiting';
  }
}

@immutable
class EnrolmentUpdateBodyEnded extends EnrolmentUpdateBody {
  const EnrolmentUpdateBodyEnded({
    required this.value,
  }) : super();

  static EnrolmentUpdateBodyEnded load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentUpdateBodyEnded(
      value: EnrolmentEndView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final EnrolmentEndView value;

  EnrolmentUpdateBodyEnded copyWith({
    EnrolmentEndView? value,
  }) {
    return EnrolmentUpdateBodyEnded(
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

    return other is EnrolmentUpdateBodyEnded
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

    return fullString ?? 'EnrolmentUpdateBodyEnded';
  }
}
