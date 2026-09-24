// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// How a pairing window ended.
abstract class EnrolmentEndView {
  const EnrolmentEndView();

  void serialize(BinarySerializer serializer);

  static EnrolmentEndView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return EnrolmentEndViewEnrolled.load(deserializer);
      case 1: return EnrolmentEndViewDeclined.load(deserializer);
      case 2: return EnrolmentEndViewUnconfirmed.load(deserializer);
      case 3: return EnrolmentEndViewNotStored.load(deserializer);
      case 4: return EnrolmentEndViewExpired.load(deserializer);
      case 5: return EnrolmentEndViewCancelled.load(deserializer);
      case 6: return EnrolmentEndViewFailed.load(deserializer);
      default: throw Exception('Unknown variant index for EnrolmentEndView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static EnrolmentEndView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EnrolmentEndView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class EnrolmentEndViewEnrolled extends EnrolmentEndView {
  const EnrolmentEndViewEnrolled({
    required this.value,
  }) : super();

  static EnrolmentEndViewEnrolled load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentEndViewEnrolled(
      value: DeviceView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final DeviceView value;

  EnrolmentEndViewEnrolled copyWith({
    DeviceView? value,
  }) {
    return EnrolmentEndViewEnrolled(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentEndViewEnrolled
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

    return fullString ?? 'EnrolmentEndViewEnrolled';
  }
}

@immutable
class EnrolmentEndViewDeclined extends EnrolmentEndView {
  const EnrolmentEndViewDeclined({
    required this.deviceId,
  }) : super();

  static EnrolmentEndViewDeclined load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentEndViewDeclined(
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;

  EnrolmentEndViewDeclined copyWith({
    String? deviceId,
  }) {
    return EnrolmentEndViewDeclined(
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(deviceId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentEndViewDeclined
      && deviceId == other.deviceId;
  }

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId'
        ')';
      return true;
    }());

    return fullString ?? 'EnrolmentEndViewDeclined';
  }
}

@immutable
class EnrolmentEndViewUnconfirmed extends EnrolmentEndView {
  const EnrolmentEndViewUnconfirmed({
    required this.deviceId,
  }) : super();

  static EnrolmentEndViewUnconfirmed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentEndViewUnconfirmed(
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;

  EnrolmentEndViewUnconfirmed copyWith({
    String? deviceId,
  }) {
    return EnrolmentEndViewUnconfirmed(
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeString(deviceId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentEndViewUnconfirmed
      && deviceId == other.deviceId;
  }

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId'
        ')';
      return true;
    }());

    return fullString ?? 'EnrolmentEndViewUnconfirmed';
  }
}

@immutable
class EnrolmentEndViewNotStored extends EnrolmentEndView {
  const EnrolmentEndViewNotStored({
    required this.deviceId,
    required this.message,
  }) : super();

  static EnrolmentEndViewNotStored load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentEndViewNotStored(
      deviceId: deserializer.deserializeString(),
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String message;

  EnrolmentEndViewNotStored copyWith({
    String? deviceId,
    String? message,
  }) {
    return EnrolmentEndViewNotStored(
      deviceId: deviceId ?? this.deviceId,
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeString(deviceId);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentEndViewNotStored
      && deviceId == other.deviceId
      && message == other.message;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        message,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId, '
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'EnrolmentEndViewNotStored';
  }
}

@immutable
class EnrolmentEndViewExpired extends EnrolmentEndView {
  const EnrolmentEndViewExpired(
  ) : super();

  static EnrolmentEndViewExpired load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentEndViewExpired(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentEndViewExpired;
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

    return fullString ?? 'EnrolmentEndViewExpired';
  }
}

@immutable
class EnrolmentEndViewCancelled extends EnrolmentEndView {
  const EnrolmentEndViewCancelled(
  ) : super();

  static EnrolmentEndViewCancelled load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentEndViewCancelled(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentEndViewCancelled;
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

    return fullString ?? 'EnrolmentEndViewCancelled';
  }
}

@immutable
class EnrolmentEndViewFailed extends EnrolmentEndView {
  const EnrolmentEndViewFailed({
    required this.message,
  }) : super();

  static EnrolmentEndViewFailed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EnrolmentEndViewFailed(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  EnrolmentEndViewFailed copyWith({
    String? message,
  }) {
    return EnrolmentEndViewFailed(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EnrolmentEndViewFailed
      && message == other.message;
  }

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'EnrolmentEndViewFailed';
  }
}
