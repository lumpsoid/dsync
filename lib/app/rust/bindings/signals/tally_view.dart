// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One side's SPEC §5.2 counts, with what they come to: every path the
/// scan checked, and those it found changed - every path not scanned
/// unchanged.
@immutable
class TallyView {
  const TallyView({
    required this.metadataMatched,
    required this.hashMatched,
    required this.modified,
    required this.created,
    required this.deleted,
    required this.total,
    required this.changed,
  });

  static TallyView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TallyView(
      metadataMatched: deserializer.deserializeUint64(),
      hashMatched: deserializer.deserializeUint64(),
      modified: deserializer.deserializeUint64(),
      created: deserializer.deserializeUint64(),
      deleted: deserializer.deserializeUint64(),
      total: deserializer.deserializeUint64(),
      changed: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TallyView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TallyView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 metadataMatched;
  final Uint64 hashMatched;
  final Uint64 modified;
  final Uint64 created;
  final Uint64 deleted;
  final Uint64 total;
  final Uint64 changed;

  TallyView copyWith({
    Uint64? metadataMatched,
    Uint64? hashMatched,
    Uint64? modified,
    Uint64? created,
    Uint64? deleted,
    Uint64? total,
    Uint64? changed,
  }) {
    return TallyView(
      metadataMatched: metadataMatched ?? this.metadataMatched,
      hashMatched: hashMatched ?? this.hashMatched,
      modified: modified ?? this.modified,
      created: created ?? this.created,
      deleted: deleted ?? this.deleted,
      total: total ?? this.total,
      changed: changed ?? this.changed,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(metadataMatched);
    serializer.serializeUint64(hashMatched);
    serializer.serializeUint64(modified);
    serializer.serializeUint64(created);
    serializer.serializeUint64(deleted);
    serializer.serializeUint64(total);
    serializer.serializeUint64(changed);
    serializer.decreaseContainerDepth();
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is TallyView
      && metadataMatched == other.metadataMatched
      && hashMatched == other.hashMatched
      && modified == other.modified
      && created == other.created
      && deleted == other.deleted
      && total == other.total
      && changed == other.changed;
  }

  @override
  int get hashCode => Object.hash(
        metadataMatched,
        hashMatched,
        modified,
        created,
        deleted,
        total,
        changed,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'metadataMatched: $metadataMatched, '
        'hashMatched: $hashMatched, '
        'modified: $modified, '
        'created: $created, '
        'deleted: $deleted, '
        'total: $total, '
        'changed: $changed'
        ')';
      return true;
    }());

    return fullString ?? 'TallyView';
  }
}
