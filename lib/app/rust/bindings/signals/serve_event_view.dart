// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class ServeEventView {
  const ServeEventView();

  void serialize(BinarySerializer serializer);

  static ServeEventView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ServeEventViewRefused.load(deserializer);
      case 1: return ServeEventViewStarted.load(deserializer);
      case 2: return ServeEventViewServing.load(deserializer);
      case 3: return ServeEventViewEnded.load(deserializer);
      default: throw Exception('Unknown variant index for ServeEventView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ServeEventView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeEventView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ServeEventViewRefused extends ServeEventView {
  const ServeEventViewRefused({
    required this.from,
    required this.message,
  }) : super();

  static ServeEventViewRefused load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeEventViewRefused(
      from: deserializer.deserializeString(),
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String from;
  final String message;

  ServeEventViewRefused copyWith({
    String? from,
    String? message,
  }) {
    return ServeEventViewRefused(
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

    return other is ServeEventViewRefused
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

    return fullString ?? 'ServeEventViewRefused';
  }
}

@immutable
class ServeEventViewStarted extends ServeEventView {
  const ServeEventViewStarted({
    required this.from,
    required this.deviceId,
    required this.name,
  }) : super();

  static ServeEventViewStarted load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeEventViewStarted(
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

  ServeEventViewStarted copyWith({
    String? from,
    String? deviceId,
    String? name,
  }) {
    return ServeEventViewStarted(
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

    return other is ServeEventViewStarted
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

    return fullString ?? 'ServeEventViewStarted';
  }
}

@immutable
class ServeEventViewServing extends ServeEventView {
  const ServeEventViewServing({
    required this.root,
  }) : super();

  static ServeEventViewServing load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeEventViewServing(
      root: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String root;

  ServeEventViewServing copyWith({
    String? root,
  }) {
    return ServeEventViewServing(
      root: root ?? this.root,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeString(root);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ServeEventViewServing
      && root == other.root;
  }

  @override
  int get hashCode => root.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'root: $root'
        ')';
      return true;
    }());

    return fullString ?? 'ServeEventViewServing';
  }
}

@immutable
class ServeEventViewEnded extends ServeEventView {
  const ServeEventViewEnded({
    required this.from,
    required this.deviceId,
    required this.name,
    this.failure,
  }) : super();

  static ServeEventViewEnded load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeEventViewEnded(
      from: deserializer.deserializeString(),
      deviceId: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
      failure: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String from;
  final String deviceId;
  final String name;
  final String? failure;

  ServeEventViewEnded copyWith({
    String? from,
    String? deviceId,
    String? name,
    String? Function()? failure,
  }) {
    return ServeEventViewEnded(
      from: from ?? this.from,
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
      failure: failure == null ? this.failure : failure(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeString(from);
    serializer.serializeString(deviceId);
    serializer.serializeString(name);
    TraitHelpers.serializeOptionStr(failure, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ServeEventViewEnded
      && from == other.from
      && deviceId == other.deviceId
      && name == other.name
      && failure == other.failure;
  }

  @override
  int get hashCode => Object.hash(
        from,
        deviceId,
        name,
        failure,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'from: $from, '
        'deviceId: $deviceId, '
        'name: $name, '
        'failure: $failure'
        ')';
      return true;
    }());

    return fullString ?? 'ServeEventViewEnded';
  }
}
