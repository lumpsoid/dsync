// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A peer probe's answer. `Unreachable`: only the address is in doubt.
/// `Refused`: something answered and the pairing or a certificate is the
/// problem.
abstract class ProbeOutcome {
  const ProbeOutcome();

  void serialize(BinarySerializer serializer);

  static ProbeOutcome deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ProbeOutcomeReachable.load(deserializer);
      case 1: return ProbeOutcomeUnreachable.load(deserializer);
      case 2: return ProbeOutcomeRefused.load(deserializer);
      default: throw Exception('Unknown variant index for ProbeOutcome: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ProbeOutcome bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ProbeOutcome.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ProbeOutcomeReachable extends ProbeOutcome {
  const ProbeOutcomeReachable({
    required this.address,
  }) : super();

  static ProbeOutcomeReachable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProbeOutcomeReachable(
      address: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String address;

  ProbeOutcomeReachable copyWith({
    String? address,
  }) {
    return ProbeOutcomeReachable(
      address: address ?? this.address,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(address);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ProbeOutcomeReachable
      && address == other.address;
  }

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'address: $address'
        ')';
      return true;
    }());

    return fullString ?? 'ProbeOutcomeReachable';
  }
}

@immutable
class ProbeOutcomeUnreachable extends ProbeOutcome {
  const ProbeOutcomeUnreachable({
    required this.message,
  }) : super();

  static ProbeOutcomeUnreachable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProbeOutcomeUnreachable(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  ProbeOutcomeUnreachable copyWith({
    String? message,
  }) {
    return ProbeOutcomeUnreachable(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ProbeOutcomeUnreachable
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

    return fullString ?? 'ProbeOutcomeUnreachable';
  }
}

@immutable
class ProbeOutcomeRefused extends ProbeOutcome {
  const ProbeOutcomeRefused({
    required this.message,
  }) : super();

  static ProbeOutcomeRefused load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProbeOutcomeRefused(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  ProbeOutcomeRefused copyWith({
    String? message,
  }) {
    return ProbeOutcomeRefused(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ProbeOutcomeRefused
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

    return fullString ?? 'ProbeOutcomeRefused';
  }
}
