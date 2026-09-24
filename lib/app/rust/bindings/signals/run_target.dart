// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What a run syncs: a saved profile, or a one-off pair.
abstract class RunTarget {
  const RunTarget();

  void serialize(BinarySerializer serializer);

  static RunTarget deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return RunTargetProfile.load(deserializer);
      case 1: return RunTargetPair.load(deserializer);
      default: throw Exception('Unknown variant index for RunTarget: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static RunTarget bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RunTarget.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class RunTargetProfile extends RunTarget {
  const RunTargetProfile({
    required this.name,
  }) : super();

  static RunTargetProfile load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunTargetProfile(
      name: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String name;

  RunTargetProfile copyWith({
    String? name,
  }) {
    return RunTargetProfile(
      name: name ?? this.name,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(name);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunTargetProfile
      && name == other.name;
  }

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'name: $name'
        ')';
      return true;
    }());

    return fullString ?? 'RunTargetProfile';
  }
}

@immutable
class RunTargetPair extends RunTarget {
  const RunTargetPair({
    required this.draft,
  }) : super();

  static RunTargetPair load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = RunTargetPair(
      draft: ProfileDraft.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ProfileDraft draft;

  RunTargetPair copyWith({
    ProfileDraft? draft,
  }) {
    return RunTargetPair(
      draft: draft ?? this.draft,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    draft.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is RunTargetPair
      && draft == other.draft;
  }

  @override
  int get hashCode => draft.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'draft: $draft'
        ')';
      return true;
    }());

    return fullString ?? 'RunTargetPair';
  }
}
