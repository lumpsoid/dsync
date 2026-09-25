// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class ActionView {
  const ActionView();

  void serialize(BinarySerializer serializer);

  static ActionView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ActionViewCopy.load(deserializer);
      case 1: return ActionViewCopyAside.load(deserializer);
      case 2: return ActionViewDelete.load(deserializer);
      case 3: return ActionViewCommitOnly.load(deserializer);
      default: throw Exception('Unknown variant index for ActionView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ActionView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ActionView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ActionViewCopy extends ActionView {
  const ActionViewCopy({
    required this.path,
    required this.from,
    required this.bytes,
  }) : super();

  static ActionViewCopy load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ActionViewCopy(
      path: deserializer.deserializeString(),
      from: SideViewExtension.deserialize(deserializer),
      bytes: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String path;
  final SideView from;
  final Uint64 bytes;

  ActionViewCopy copyWith({
    String? path,
    SideView? from,
    Uint64? bytes,
  }) {
    return ActionViewCopy(
      path: path ?? this.path,
      from: from ?? this.from,
      bytes: bytes ?? this.bytes,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(path);
    from.serialize(serializer);
    serializer.serializeUint64(bytes);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ActionViewCopy
      && path == other.path
      && from == other.from
      && bytes == other.bytes;
  }

  @override
  int get hashCode => Object.hash(
        path,
        from,
        bytes,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'from: $from, '
        'bytes: $bytes'
        ')';
      return true;
    }());

    return fullString ?? 'ActionViewCopy';
  }
}

@immutable
class ActionViewCopyAside extends ActionView {
  const ActionViewCopyAside({
    required this.path,
    required this.from,
    required this.to,
    required this.bytes,
  }) : super();

  static ActionViewCopyAside load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ActionViewCopyAside(
      path: deserializer.deserializeString(),
      from: SideViewExtension.deserialize(deserializer),
      to: deserializer.deserializeString(),
      bytes: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String path;
  final SideView from;
  final String to;
  final Uint64 bytes;

  ActionViewCopyAside copyWith({
    String? path,
    SideView? from,
    String? to,
    Uint64? bytes,
  }) {
    return ActionViewCopyAside(
      path: path ?? this.path,
      from: from ?? this.from,
      to: to ?? this.to,
      bytes: bytes ?? this.bytes,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(path);
    from.serialize(serializer);
    serializer.serializeString(to);
    serializer.serializeUint64(bytes);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ActionViewCopyAside
      && path == other.path
      && from == other.from
      && to == other.to
      && bytes == other.bytes;
  }

  @override
  int get hashCode => Object.hash(
        path,
        from,
        to,
        bytes,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'from: $from, '
        'to: $to, '
        'bytes: $bytes'
        ')';
      return true;
    }());

    return fullString ?? 'ActionViewCopyAside';
  }
}

@immutable
class ActionViewDelete extends ActionView {
  const ActionViewDelete({
    required this.path,
    required this.on,
  }) : super();

  static ActionViewDelete load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ActionViewDelete(
      path: deserializer.deserializeString(),
      on: SideViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String path;
  final SideView on;

  ActionViewDelete copyWith({
    String? path,
    SideView? on,
  }) {
    return ActionViewDelete(
      path: path ?? this.path,
      on: on ?? this.on,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeString(path);
    on.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ActionViewDelete
      && path == other.path
      && on == other.on;
  }

  @override
  int get hashCode => Object.hash(
        path,
        on,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'on: $on'
        ')';
      return true;
    }());

    return fullString ?? 'ActionViewDelete';
  }
}

@immutable
class ActionViewCommitOnly extends ActionView {
  const ActionViewCommitOnly({
    required this.path,
  }) : super();

  static ActionViewCommitOnly load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ActionViewCommitOnly(
      path: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String path;

  ActionViewCommitOnly copyWith({
    String? path,
  }) {
    return ActionViewCommitOnly(
      path: path ?? this.path,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeString(path);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ActionViewCommitOnly
      && path == other.path;
  }

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path'
        ')';
      return true;
    }());

    return fullString ?? 'ActionViewCommitOnly';
  }
}
