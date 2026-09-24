// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class TallyView {
  const TallyView({
    required this.metadataMatched,
    required this.hashMatched,
    required this.modified,
    required this.created,
    required this.deleted,
    required this.untrusted,
  });

  static TallyView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TallyView(
      metadataMatched: deserializer.deserializeUint64(),
      hashMatched: deserializer.deserializeUint64(),
      modified: deserializer.deserializeUint64(),
      created: deserializer.deserializeUint64(),
      deleted: deserializer.deserializeUint64(),
      untrusted: deserializer.deserializeUint64(),
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
  final Uint64 untrusted;

  TallyView copyWith({
    Uint64? metadataMatched,
    Uint64? hashMatched,
    Uint64? modified,
    Uint64? created,
    Uint64? deleted,
    Uint64? untrusted,
  }) {
    return TallyView(
      metadataMatched: metadataMatched ?? this.metadataMatched,
      hashMatched: hashMatched ?? this.hashMatched,
      modified: modified ?? this.modified,
      created: created ?? this.created,
      deleted: deleted ?? this.deleted,
      untrusted: untrusted ?? this.untrusted,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(metadataMatched);
    serializer.serializeUint64(hashMatched);
    serializer.serializeUint64(modified);
    serializer.serializeUint64(created);
    serializer.serializeUint64(deleted);
    serializer.serializeUint64(untrusted);
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
      && untrusted == other.untrusted;
  }

  @override
  int get hashCode => Object.hash(
        metadataMatched,
        hashMatched,
        modified,
        created,
        deleted,
        untrusted,
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
        'untrusted: $untrusted'
        ')';
      return true;
    }());

    return fullString ?? 'TallyView';
  }
}
