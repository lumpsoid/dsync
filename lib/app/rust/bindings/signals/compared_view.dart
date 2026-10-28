// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What the compare found: left unread (media, over the cap), unreadable
/// as text (binary, a failed read), or both texts' line diff - the same
/// text, or the hunks that differ.
abstract class ComparedView {
  const ComparedView();

  void serialize(BinarySerializer serializer);

  static ComparedView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ComparedViewMedia.load(deserializer);
      case 1: return ComparedViewTooLarge.load(deserializer);
      case 2: return ComparedViewBinary.load(deserializer);
      case 3: return ComparedViewUnreadable.load(deserializer);
      case 4: return ComparedViewIdentical.load(deserializer);
      case 5: return ComparedViewHunks.load(deserializer);
      default: throw Exception('Unknown variant index for ComparedView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ComparedView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComparedView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ComparedViewMedia extends ComparedView {
  const ComparedViewMedia(
  ) : super();

  static ComparedViewMedia load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComparedViewMedia(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComparedViewMedia;
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

    return fullString ?? 'ComparedViewMedia';
  }
}

@immutable
class ComparedViewTooLarge extends ComparedView {
  const ComparedViewTooLarge({
    required this.side,
    required this.size,
  }) : super();

  static ComparedViewTooLarge load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComparedViewTooLarge(
      side: SideViewExtension.deserialize(deserializer),
      size: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SideView side;
  final Uint64 size;

  ComparedViewTooLarge copyWith({
    SideView? side,
    Uint64? size,
  }) {
    return ComparedViewTooLarge(
      side: side ?? this.side,
      size: size ?? this.size,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    side.serialize(serializer);
    serializer.serializeUint64(size);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComparedViewTooLarge
      && side == other.side
      && size == other.size;
  }

  @override
  int get hashCode => Object.hash(
        side,
        size,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side, '
        'size: $size'
        ')';
      return true;
    }());

    return fullString ?? 'ComparedViewTooLarge';
  }
}

@immutable
class ComparedViewBinary extends ComparedView {
  const ComparedViewBinary({
    required this.side,
  }) : super();

  static ComparedViewBinary load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComparedViewBinary(
      side: SideViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SideView side;

  ComparedViewBinary copyWith({
    SideView? side,
  }) {
    return ComparedViewBinary(
      side: side ?? this.side,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    side.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComparedViewBinary
      && side == other.side;
  }

  @override
  int get hashCode => side.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side'
        ')';
      return true;
    }());

    return fullString ?? 'ComparedViewBinary';
  }
}

@immutable
class ComparedViewUnreadable extends ComparedView {
  const ComparedViewUnreadable({
    required this.side,
    required this.message,
  }) : super();

  static ComparedViewUnreadable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComparedViewUnreadable(
      side: SideViewExtension.deserialize(deserializer),
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SideView side;
  final String message;

  ComparedViewUnreadable copyWith({
    SideView? side,
    String? message,
  }) {
    return ComparedViewUnreadable(
      side: side ?? this.side,
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    side.serialize(serializer);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComparedViewUnreadable
      && side == other.side
      && message == other.message;
  }

  @override
  int get hashCode => Object.hash(
        side,
        message,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side, '
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'ComparedViewUnreadable';
  }
}

@immutable
class ComparedViewIdentical extends ComparedView {
  const ComparedViewIdentical({
    required this.bytesDiffer,
  }) : super();

  static ComparedViewIdentical load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComparedViewIdentical(
      bytesDiffer: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final bool bytesDiffer;

  ComparedViewIdentical copyWith({
    bool? bytesDiffer,
  }) {
    return ComparedViewIdentical(
      bytesDiffer: bytesDiffer ?? this.bytesDiffer,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.serializeBool(bytesDiffer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComparedViewIdentical
      && bytesDiffer == other.bytesDiffer;
  }

  @override
  int get hashCode => bytesDiffer.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'bytesDiffer: $bytesDiffer'
        ')';
      return true;
    }());

    return fullString ?? 'ComparedViewIdentical';
  }
}

@immutable
class ComparedViewHunks extends ComparedView {
  const ComparedViewHunks({
    required this.value,
  }) : super();

  static ComparedViewHunks load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComparedViewHunks(
      value: TraitHelpers.deserializeVectorHunkView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<HunkView> value;

  ComparedViewHunks copyWith({
    List<HunkView>? value,
  }) {
    return ComparedViewHunks(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    TraitHelpers.serializeVectorHunkView(value, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComparedViewHunks
      && listEquals(value, other.value);
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

    return fullString ?? 'ComparedViewHunks';
  }
}
