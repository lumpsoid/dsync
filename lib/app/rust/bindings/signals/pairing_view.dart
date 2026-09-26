// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A pairing window as the head shows it, whole: sent after every change.
/// `Waiting` and `Confirming` are open; every other one is how it ended,
/// and the last it sends.
abstract class PairingView {
  const PairingView();

  void serialize(BinarySerializer serializer);

  static PairingView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return PairingViewWaiting.load(deserializer);
      case 1: return PairingViewConfirming.load(deserializer);
      case 2: return PairingViewEnrolled.load(deserializer);
      case 3: return PairingViewDeclined.load(deserializer);
      case 4: return PairingViewUnconfirmed.load(deserializer);
      case 5: return PairingViewNotStored.load(deserializer);
      case 6: return PairingViewExpired.load(deserializer);
      case 7: return PairingViewCancelled.load(deserializer);
      case 8: return PairingViewFailed.load(deserializer);
      default: throw Exception('Unknown variant index for PairingView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static PairingView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PairingView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class PairingViewWaiting extends PairingView {
  const PairingViewWaiting({
    required this.payload,
    required this.deviceId,
    required this.endpoint,
    required this.expiresAtMs,
  }) : super();

  static PairingViewWaiting load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewWaiting(
      payload: deserializer.deserializeString(),
      deviceId: deserializer.deserializeString(),
      endpoint: deserializer.deserializeString(),
      expiresAtMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String payload;
  final String deviceId;
  final String endpoint;
  final int expiresAtMs;

  PairingViewWaiting copyWith({
    String? payload,
    String? deviceId,
    String? endpoint,
    int? expiresAtMs,
  }) {
    return PairingViewWaiting(
      payload: payload ?? this.payload,
      deviceId: deviceId ?? this.deviceId,
      endpoint: endpoint ?? this.endpoint,
      expiresAtMs: expiresAtMs ?? this.expiresAtMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(payload);
    serializer.serializeString(deviceId);
    serializer.serializeString(endpoint);
    serializer.serializeInt64(expiresAtMs);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairingViewWaiting
      && payload == other.payload
      && deviceId == other.deviceId
      && endpoint == other.endpoint
      && expiresAtMs == other.expiresAtMs;
  }

  @override
  int get hashCode => Object.hash(
        payload,
        deviceId,
        endpoint,
        expiresAtMs,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'payload: $payload, '
        'deviceId: $deviceId, '
        'endpoint: $endpoint, '
        'expiresAtMs: $expiresAtMs'
        ')';
      return true;
    }());

    return fullString ?? 'PairingViewWaiting';
  }
}

@immutable
class PairingViewConfirming extends PairingView {
  const PairingViewConfirming({
    required this.deviceId,
    required this.name,
  }) : super();

  static PairingViewConfirming load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewConfirming(
      deviceId: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String name;

  PairingViewConfirming copyWith({
    String? deviceId,
    String? name,
  }) {
    return PairingViewConfirming(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(deviceId);
    serializer.serializeString(name);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairingViewConfirming
      && deviceId == other.deviceId
      && name == other.name;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        name,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId, '
        'name: $name'
        ')';
      return true;
    }());

    return fullString ?? 'PairingViewConfirming';
  }
}

@immutable
class PairingViewEnrolled extends PairingView {
  const PairingViewEnrolled({
    required this.value,
  }) : super();

  static PairingViewEnrolled load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewEnrolled(
      value: DeviceView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final DeviceView value;

  PairingViewEnrolled copyWith({
    DeviceView? value,
  }) {
    return PairingViewEnrolled(
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

    return other is PairingViewEnrolled
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

    return fullString ?? 'PairingViewEnrolled';
  }
}

@immutable
class PairingViewDeclined extends PairingView {
  const PairingViewDeclined({
    required this.deviceId,
  }) : super();

  static PairingViewDeclined load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewDeclined(
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;

  PairingViewDeclined copyWith({
    String? deviceId,
  }) {
    return PairingViewDeclined(
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeString(deviceId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairingViewDeclined
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

    return fullString ?? 'PairingViewDeclined';
  }
}

@immutable
class PairingViewUnconfirmed extends PairingView {
  const PairingViewUnconfirmed({
    required this.deviceId,
  }) : super();

  static PairingViewUnconfirmed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewUnconfirmed(
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;

  PairingViewUnconfirmed copyWith({
    String? deviceId,
  }) {
    return PairingViewUnconfirmed(
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.serializeString(deviceId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairingViewUnconfirmed
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

    return fullString ?? 'PairingViewUnconfirmed';
  }
}

@immutable
class PairingViewNotStored extends PairingView {
  const PairingViewNotStored({
    required this.deviceId,
    required this.message,
  }) : super();

  static PairingViewNotStored load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewNotStored(
      deviceId: deserializer.deserializeString(),
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String message;

  PairingViewNotStored copyWith({
    String? deviceId,
    String? message,
  }) {
    return PairingViewNotStored(
      deviceId: deviceId ?? this.deviceId,
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.serializeString(deviceId);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairingViewNotStored
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

    return fullString ?? 'PairingViewNotStored';
  }
}

@immutable
class PairingViewExpired extends PairingView {
  const PairingViewExpired({
    required this.windowSeconds,
  }) : super();

  static PairingViewExpired load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewExpired(
      windowSeconds: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 windowSeconds;

  PairingViewExpired copyWith({
    Uint64? windowSeconds,
  }) {
    return PairingViewExpired(
      windowSeconds: windowSeconds ?? this.windowSeconds,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    serializer.serializeUint64(windowSeconds);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairingViewExpired
      && windowSeconds == other.windowSeconds;
  }

  @override
  int get hashCode => windowSeconds.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'windowSeconds: $windowSeconds'
        ')';
      return true;
    }());

    return fullString ?? 'PairingViewExpired';
  }
}

@immutable
class PairingViewCancelled extends PairingView {
  const PairingViewCancelled(
  ) : super();

  static PairingViewCancelled load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewCancelled(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairingViewCancelled;
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

    return fullString ?? 'PairingViewCancelled';
  }
}

@immutable
class PairingViewFailed extends PairingView {
  const PairingViewFailed({
    required this.message,
  }) : super();

  static PairingViewFailed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairingViewFailed(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  PairingViewFailed copyWith({
    String? message,
  }) {
    return PairingViewFailed(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairingViewFailed
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

    return fullString ?? 'PairingViewFailed';
  }
}
