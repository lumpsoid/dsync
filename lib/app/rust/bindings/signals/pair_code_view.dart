// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A scanned or pasted pairing code, before it is redeemed.
abstract class PairCodeView {
  const PairCodeView();

  void serialize(BinarySerializer serializer);

  static PairCodeView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return PairCodeViewUnreadable.load(deserializer);
      case 1: return PairCodeViewRead.load(deserializer);
      default: throw Exception('Unknown variant index for PairCodeView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static PairCodeView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PairCodeView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class PairCodeViewUnreadable extends PairCodeView {
  const PairCodeViewUnreadable({
    required this.message,
  }) : super();

  static PairCodeViewUnreadable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairCodeViewUnreadable(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  PairCodeViewUnreadable copyWith({
    String? message,
  }) {
    return PairCodeViewUnreadable(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairCodeViewUnreadable
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

    return fullString ?? 'PairCodeViewUnreadable';
  }
}

@immutable
class PairCodeViewRead extends PairCodeView {
  const PairCodeViewRead({
    required this.desktopName,
    required this.address,
    this.deviceId,
  }) : super();

  static PairCodeViewRead load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PairCodeViewRead(
      desktopName: deserializer.deserializeString(),
      address: deserializer.deserializeString(),
      deviceId: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String desktopName;
  final String address;
  final String? deviceId;

  PairCodeViewRead copyWith({
    String? desktopName,
    String? address,
    String? Function()? deviceId,
  }) {
    return PairCodeViewRead(
      desktopName: desktopName ?? this.desktopName,
      address: address ?? this.address,
      deviceId: deviceId == null ? this.deviceId : deviceId(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(desktopName);
    serializer.serializeString(address);
    TraitHelpers.serializeOptionStr(deviceId, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PairCodeViewRead
      && desktopName == other.desktopName
      && address == other.address
      && deviceId == other.deviceId;
  }

  @override
  int get hashCode => Object.hash(
        desktopName,
        address,
        deviceId,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'desktopName: $desktopName, '
        'address: $address, '
        'deviceId: $deviceId'
        ')';
      return true;
    }());

    return fullString ?? 'PairCodeViewRead';
  }
}
