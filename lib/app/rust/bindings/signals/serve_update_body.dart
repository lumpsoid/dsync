// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class ServeUpdateBody {
  const ServeUpdateBody();

  void serialize(BinarySerializer serializer);

  static ServeUpdateBody deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ServeUpdateBodyRefused.load(deserializer);
      case 1: return ServeUpdateBodyStarted.load(deserializer);
      case 2: return ServeUpdateBodyServing.load(deserializer);
      case 3: return ServeUpdateBodyEnded.load(deserializer);
      case 4: return ServeUpdateBodyStopped.load(deserializer);
      default: throw Exception('Unknown variant index for ServeUpdateBody: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ServeUpdateBody bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeUpdateBody.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ServeUpdateBodyRefused extends ServeUpdateBody {
  const ServeUpdateBodyRefused({
    required this.from,
    required this.message,
  }) : super();

  static ServeUpdateBodyRefused load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeUpdateBodyRefused(
      from: deserializer.deserializeString(),
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String from;
  final String message;

  ServeUpdateBodyRefused copyWith({
    String? from,
    String? message,
  }) {
    return ServeUpdateBodyRefused(
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

    return other is ServeUpdateBodyRefused
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

    return fullString ?? 'ServeUpdateBodyRefused';
  }
}

@immutable
class ServeUpdateBodyStarted extends ServeUpdateBody {
  const ServeUpdateBodyStarted({
    required this.from,
    required this.deviceId,
    required this.name,
  }) : super();

  static ServeUpdateBodyStarted load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeUpdateBodyStarted(
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

  ServeUpdateBodyStarted copyWith({
    String? from,
    String? deviceId,
    String? name,
  }) {
    return ServeUpdateBodyStarted(
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

    return other is ServeUpdateBodyStarted
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

    return fullString ?? 'ServeUpdateBodyStarted';
  }
}

@immutable
class ServeUpdateBodyServing extends ServeUpdateBody {
  const ServeUpdateBodyServing({
    required this.root,
  }) : super();

  static ServeUpdateBodyServing load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeUpdateBodyServing(
      root: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String root;

  ServeUpdateBodyServing copyWith({
    String? root,
  }) {
    return ServeUpdateBodyServing(
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

    return other is ServeUpdateBodyServing
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

    return fullString ?? 'ServeUpdateBodyServing';
  }
}

@immutable
class ServeUpdateBodyEnded extends ServeUpdateBody {
  const ServeUpdateBodyEnded({
    required this.from,
    required this.deviceId,
    required this.name,
    this.failure,
  }) : super();

  static ServeUpdateBodyEnded load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeUpdateBodyEnded(
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

  ServeUpdateBodyEnded copyWith({
    String? from,
    String? deviceId,
    String? name,
    String? Function()? failure,
  }) {
    return ServeUpdateBodyEnded(
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

    return other is ServeUpdateBodyEnded
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

    return fullString ?? 'ServeUpdateBodyEnded';
  }
}

@immutable
class ServeUpdateBodyStopped extends ServeUpdateBody {
  const ServeUpdateBodyStopped({
    this.failure,
  }) : super();

  static ServeUpdateBodyStopped load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeUpdateBodyStopped(
      failure: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String? failure;

  ServeUpdateBodyStopped copyWith({
    String? Function()? failure,
  }) {
    return ServeUpdateBodyStopped(
      failure: failure == null ? this.failure : failure(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    TraitHelpers.serializeOptionStr(failure, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ServeUpdateBodyStopped
      && failure == other.failure;
  }

  @override
  int get hashCode => failure.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'failure: $failure'
        ')';
      return true;
    }());

    return fullString ?? 'ServeUpdateBodyStopped';
  }
}
