// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class ServePhaseView {
  const ServePhaseView();

  void serialize(BinarySerializer serializer);

  static ServePhaseView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ServePhaseViewListening.load(deserializer);
      case 1: return ServePhaseViewStopped.load(deserializer);
      case 2: return ServePhaseViewFailed.load(deserializer);
      default: throw Exception('Unknown variant index for ServePhaseView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ServePhaseView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServePhaseView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ServePhaseViewListening extends ServePhaseView {
  const ServePhaseViewListening({
    required this.advertised,
  }) : super();

  static ServePhaseViewListening load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServePhaseViewListening(
      advertised: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String advertised;

  ServePhaseViewListening copyWith({
    String? advertised,
  }) {
    return ServePhaseViewListening(
      advertised: advertised ?? this.advertised,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(advertised);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ServePhaseViewListening
      && advertised == other.advertised;
  }

  @override
  int get hashCode => advertised.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'advertised: $advertised'
        ')';
      return true;
    }());

    return fullString ?? 'ServePhaseViewListening';
  }
}

@immutable
class ServePhaseViewStopped extends ServePhaseView {
  const ServePhaseViewStopped(
  ) : super();

  static ServePhaseViewStopped load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServePhaseViewStopped(
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

    return other is ServePhaseViewStopped;
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

    return fullString ?? 'ServePhaseViewStopped';
  }
}

@immutable
class ServePhaseViewFailed extends ServePhaseView {
  const ServePhaseViewFailed({
    required this.message,
  }) : super();

  static ServePhaseViewFailed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServePhaseViewFailed(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  ServePhaseViewFailed copyWith({
    String? message,
  }) {
    return ServePhaseViewFailed(
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

    return other is ServePhaseViewFailed
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

    return fullString ?? 'ServePhaseViewFailed';
  }
}
