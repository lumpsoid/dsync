// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What the pair has behind it, from each side's last commit: a side with
/// none has no archive, so this run is a first sync (SPEC §6) - a path
/// present on one side only is copied, never deleted.
abstract class HistoryView {
  const HistoryView();

  void serialize(BinarySerializer serializer);

  static HistoryView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return HistoryViewFirstSync.load(deserializer);
      case 1: return HistoryViewOneSided.load(deserializer);
      case 2: return HistoryViewSynced.load(deserializer);
      default: throw Exception('Unknown variant index for HistoryView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static HistoryView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = HistoryView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class HistoryViewFirstSync extends HistoryView {
  const HistoryViewFirstSync(
  ) : super();

  static HistoryViewFirstSync load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = HistoryViewFirstSync(
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

    return other is HistoryViewFirstSync;
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

    return fullString ?? 'HistoryViewFirstSync';
  }
}

@immutable
class HistoryViewOneSided extends HistoryView {
  const HistoryViewOneSided({
    required this.empty,
  }) : super();

  static HistoryViewOneSided load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = HistoryViewOneSided(
      empty: SideViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final SideView empty;

  HistoryViewOneSided copyWith({
    SideView? empty,
  }) {
    return HistoryViewOneSided(
      empty: empty ?? this.empty,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    empty.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is HistoryViewOneSided
      && empty == other.empty;
  }

  @override
  int get hashCode => empty.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'empty: $empty'
        ')';
      return true;
    }());

    return fullString ?? 'HistoryViewOneSided';
  }
}

@immutable
class HistoryViewSynced extends HistoryView {
  const HistoryViewSynced({
    required this.lastAMs,
    required this.lastBMs,
  }) : super();

  static HistoryViewSynced load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = HistoryViewSynced(
      lastAMs: deserializer.deserializeInt64(),
      lastBMs: deserializer.deserializeInt64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final int lastAMs;
  final int lastBMs;

  HistoryViewSynced copyWith({
    int? lastAMs,
    int? lastBMs,
  }) {
    return HistoryViewSynced(
      lastAMs: lastAMs ?? this.lastAMs,
      lastBMs: lastBMs ?? this.lastBMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeInt64(lastAMs);
    serializer.serializeInt64(lastBMs);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is HistoryViewSynced
      && lastAMs == other.lastAMs
      && lastBMs == other.lastBMs;
  }

  @override
  int get hashCode => Object.hash(
        lastAMs,
        lastBMs,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'lastAMs: $lastAMs, '
        'lastBMs: $lastBMs'
        ')';
      return true;
    }());

    return fullString ?? 'HistoryViewSynced';
  }
}
