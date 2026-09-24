// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The filter preview: every folder in pre-order (a folder's subfolders
/// follow it, one `depth` deeper), what each rule excluded, and the
/// folders that could not be listed.
@immutable
class FilterPreviewView {
  const FilterPreviewView({
    required this.folders,
    required this.excludedByRule,
    required this.unreadableFolders,
  });

  static FilterPreviewView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = FilterPreviewView(
      folders: TraitHelpers.deserializeVectorFilterFolderView(deserializer),
      excludedByRule: TraitHelpers.deserializeVectorRuleCountView(deserializer),
      unreadableFolders: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static FilterPreviewView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = FilterPreviewView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final List<FilterFolderView> folders;
  final List<RuleCountView> excludedByRule;
  final List<String> unreadableFolders;

  FilterPreviewView copyWith({
    List<FilterFolderView>? folders,
    List<RuleCountView>? excludedByRule,
    List<String>? unreadableFolders,
  }) {
    return FilterPreviewView(
      folders: folders ?? this.folders,
      excludedByRule: excludedByRule ?? this.excludedByRule,
      unreadableFolders: unreadableFolders ?? this.unreadableFolders,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeVectorFilterFolderView(folders, serializer);
    TraitHelpers.serializeVectorRuleCountView(excludedByRule, serializer);
    TraitHelpers.serializeVectorStr(unreadableFolders, serializer);
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

    return other is FilterPreviewView
      && listEquals(folders, other.folders)
      && listEquals(excludedByRule, other.excludedByRule)
      && listEquals(unreadableFolders, other.unreadableFolders);
  }

  @override
  int get hashCode => Object.hash(
        folders,
        excludedByRule,
        unreadableFolders,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'folders: $folders, '
        'excludedByRule: $excludedByRule, '
        'unreadableFolders: $unreadableFolders'
        ')';
      return true;
    }());

    return fullString ?? 'FilterPreviewView';
  }
}
