// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Where the core keeps its state (identity, pairings, archives, and the
/// head's own `settings.json` beside them) and its saved profiles.
@immutable
class DirsView {
  const DirsView({
    required this.stateDir,
    required this.profilesDir,
  });

  static DirsView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = DirsView(
      stateDir: deserializer.deserializeString(),
      profilesDir: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static DirsView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = DirsView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String stateDir;
  final String profilesDir;

  DirsView copyWith({
    String? stateDir,
    String? profilesDir,
  }) {
    return DirsView(
      stateDir: stateDir ?? this.stateDir,
      profilesDir: profilesDir ?? this.profilesDir,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(stateDir);
    serializer.serializeString(profilesDir);
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

    return other is DirsView
      && stateDir == other.stateDir
      && profilesDir == other.profilesDir;
  }

  @override
  int get hashCode => Object.hash(
        stateDir,
        profilesDir,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'stateDir: $stateDir, '
        'profilesDir: $profilesDir'
        ')';
      return true;
    }());

    return fullString ?? 'DirsView';
  }
}
