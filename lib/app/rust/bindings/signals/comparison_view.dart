// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A review row's two files set against each other (the diff page), or
/// `NotComparable` when the row has none to compare - no such row in the
/// open review, or one whose offer is [`OfferView::NotComparable`].
/// `old_side`/`new_side` (and [`BlockView`]'s `old_lines`/`new_lines`),
/// not the domain's `old`/`new`: `new` is a Dart keyword.
abstract class ComparisonView {
  const ComparisonView();

  void serialize(BinarySerializer serializer);

  static ComparisonView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ComparisonViewNotComparable.load(deserializer);
      case 1: return ComparisonViewCompared.load(deserializer);
      default: throw Exception('Unknown variant index for ComparisonView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ComparisonView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ComparisonView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ComparisonViewNotComparable extends ComparisonView {
  const ComparisonViewNotComparable(
  ) : super();

  static ComparisonViewNotComparable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComparisonViewNotComparable(
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

    return other is ComparisonViewNotComparable;
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

    return fullString ?? 'ComparisonViewNotComparable';
  }
}

@immutable
class ComparisonViewCompared extends ComparisonView {
  const ComparisonViewCompared({
    required this.path,
    required this.oldSide,
    required this.newSide,
    required this.verdict,
  }) : super();

  static ComparisonViewCompared load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ComparisonViewCompared(
      path: deserializer.deserializeString(),
      oldSide: SidedView.deserialize(deserializer),
      newSide: SidedView.deserialize(deserializer),
      verdict: ComparedView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String path;
  final SidedView oldSide;
  final SidedView newSide;
  final ComparedView verdict;

  ComparisonViewCompared copyWith({
    String? path,
    SidedView? oldSide,
    SidedView? newSide,
    ComparedView? verdict,
  }) {
    return ComparisonViewCompared(
      path: path ?? this.path,
      oldSide: oldSide ?? this.oldSide,
      newSide: newSide ?? this.newSide,
      verdict: verdict ?? this.verdict,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(path);
    oldSide.serialize(serializer);
    newSide.serialize(serializer);
    verdict.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ComparisonViewCompared
      && path == other.path
      && oldSide == other.oldSide
      && newSide == other.newSide
      && verdict == other.verdict;
  }

  @override
  int get hashCode => Object.hash(
        path,
        oldSide,
        newSide,
        verdict,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'oldSide: $oldSide, '
        'newSide: $newSide, '
        'verdict: $verdict'
        ')';
      return true;
    }());

    return fullString ?? 'ComparisonViewCompared';
  }
}
