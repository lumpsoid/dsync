// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What a review row's compare would give, known before a byte is read:
/// nothing to compare (a delete, a commit-only, a copy aside, a conflict
/// with no file on either side), the two texts, a media file left unread,
/// or `side`'s file over the read cap at `size` bytes.
abstract class OfferView {
  const OfferView();

  void serialize(BinarySerializer serializer);

  static OfferView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return OfferViewNotComparable.load(deserializer);
      case 1: return OfferViewReadable.load(deserializer);
      case 2: return OfferViewMedia.load(deserializer);
      case 3: return OfferViewTooLarge.load(deserializer);
      default: throw Exception('Unknown variant index for OfferView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static OfferView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = OfferView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class OfferViewNotComparable extends OfferView {
  const OfferViewNotComparable(
  ) : super();

  static OfferViewNotComparable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OfferViewNotComparable(
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

    return other is OfferViewNotComparable;
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

    return fullString ?? 'OfferViewNotComparable';
  }
}

@immutable
class OfferViewReadable extends OfferView {
  const OfferViewReadable(
  ) : super();

  static OfferViewReadable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OfferViewReadable(
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

    return other is OfferViewReadable;
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

    return fullString ?? 'OfferViewReadable';
  }
}

@immutable
class OfferViewMedia extends OfferView {
  const OfferViewMedia(
  ) : super();

  static OfferViewMedia load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OfferViewMedia(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is OfferViewMedia;
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

    return fullString ?? 'OfferViewMedia';
  }
}

@immutable
class OfferViewTooLarge extends OfferView {
  const OfferViewTooLarge({
    required this.side,
    required this.size,
  }) : super();

  static OfferViewTooLarge load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = OfferViewTooLarge(
      side: SideViewExtension.deserialize(deserializer),
      size: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SideView side;
  final Uint64 size;

  OfferViewTooLarge copyWith({
    SideView? side,
    Uint64? size,
  }) {
    return OfferViewTooLarge(
      side: side ?? this.side,
      size: size ?? this.size,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    side.serialize(serializer);
    serializer.serializeUint64(size);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is OfferViewTooLarge
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

    return fullString ?? 'OfferViewTooLarge';
  }
}
