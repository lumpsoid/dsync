// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One saved profile.
abstract class ProfileEntry {
  const ProfileEntry();

  void serialize(BinarySerializer serializer);

  static ProfileEntry deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ProfileEntryHead.load(deserializer);
      case 1: return ProfileEntryOther.load(deserializer);
      case 2: return ProfileEntryUnreadable.load(deserializer);
      default: throw Exception('Unknown variant index for ProfileEntry: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ProfileEntry bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ProfileEntry.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ProfileEntryHead extends ProfileEntry {
  const ProfileEntryHead({
    required this.value,
  }) : super();

  static ProfileEntryHead load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProfileEntryHead(
      value: ProfileView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ProfileView value;

  ProfileEntryHead copyWith({
    ProfileView? value,
  }) {
    return ProfileEntryHead(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ProfileEntryHead
      && value == other.value;
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

    return fullString ?? 'ProfileEntryHead';
  }
}

@immutable
class ProfileEntryOther extends ProfileEntry {
  const ProfileEntryOther({
    required this.name,
    this.profileId,
    required this.a,
    required this.b,
  }) : super();

  static ProfileEntryOther load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProfileEntryOther(
      name: deserializer.deserializeString(),
      profileId: TraitHelpers.deserializeOptionStr(deserializer),
      a: deserializer.deserializeString(),
      b: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String name;
  final String? profileId;
  final String a;
  final String b;

  ProfileEntryOther copyWith({
    String? name,
    String? Function()? profileId,
    String? a,
    String? b,
  }) {
    return ProfileEntryOther(
      name: name ?? this.name,
      profileId: profileId == null ? this.profileId : profileId(),
      a: a ?? this.a,
      b: b ?? this.b,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.serializeString(name);
    TraitHelpers.serializeOptionStr(profileId, serializer);
    serializer.serializeString(a);
    serializer.serializeString(b);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ProfileEntryOther
      && name == other.name
      && profileId == other.profileId
      && a == other.a
      && b == other.b;
  }

  @override
  int get hashCode => Object.hash(
        name,
        profileId,
        a,
        b,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'name: $name, '
        'profileId: $profileId, '
        'a: $a, '
        'b: $b'
        ')';
      return true;
    }());

    return fullString ?? 'ProfileEntryOther';
  }
}

@immutable
class ProfileEntryUnreadable extends ProfileEntry {
  const ProfileEntryUnreadable({
    required this.name,
    required this.message,
  }) : super();

  static ProfileEntryUnreadable load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProfileEntryUnreadable(
      name: deserializer.deserializeString(),
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String name;
  final String message;

  ProfileEntryUnreadable copyWith({
    String? name,
    String? message,
  }) {
    return ProfileEntryUnreadable(
      name: name ?? this.name,
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.serializeString(name);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ProfileEntryUnreadable
      && name == other.name
      && message == other.message;
  }

  @override
  int get hashCode => Object.hash(
        name,
        message,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'name: $name, '
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'ProfileEntryUnreadable';
  }
}
