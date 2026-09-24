// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One entry of a browsed folder.
@immutable
class FilterRowView {
  const FilterRowView({
    required this.path,
    required this.name,
    required this.kind,
    this.excludedBy,
    required this.syncs,
  });

  static FilterRowView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = FilterRowView(
      path: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
      kind: EntryKindView.deserialize(deserializer),
      excludedBy: TraitHelpers.deserializeOptionStr(deserializer),
      syncs: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static FilterRowView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = FilterRowView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String path;
  final String name;
  final EntryKindView kind;
  final String? excludedBy;
  final bool syncs;

  FilterRowView copyWith({
    String? path,
    String? name,
    EntryKindView? kind,
    String? Function()? excludedBy,
    bool? syncs,
  }) {
    return FilterRowView(
      path: path ?? this.path,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      excludedBy: excludedBy == null ? this.excludedBy : excludedBy(),
      syncs: syncs ?? this.syncs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(path);
    serializer.serializeString(name);
    kind.serialize(serializer);
    TraitHelpers.serializeOptionStr(excludedBy, serializer);
    serializer.serializeBool(syncs);
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

    return other is FilterRowView
      && path == other.path
      && name == other.name
      && kind == other.kind
      && excludedBy == other.excludedBy
      && syncs == other.syncs;
  }

  @override
  int get hashCode => Object.hash(
        path,
        name,
        kind,
        excludedBy,
        syncs,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'name: $name, '
        'kind: $kind, '
        'excludedBy: $excludedBy, '
        'syncs: $syncs'
        ')';
      return true;
    }());

    return fullString ?? 'FilterRowView';
  }
}
