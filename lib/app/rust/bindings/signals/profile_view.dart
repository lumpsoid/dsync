// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ProfileView {
  const ProfileView({
    required this.name,
    required this.profileId,
    required this.localRoot,
    required this.localRootExpanded,
    this.localRootRefusal,
    required this.peerDeviceId,
    this.peerName,
    required this.remoteRoot,
    this.jobs,
    required this.ignore,
    required this.lastRunUnfinished,
  });

  static ProfileView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProfileView(
      name: deserializer.deserializeString(),
      profileId: deserializer.deserializeString(),
      localRoot: deserializer.deserializeString(),
      localRootExpanded: deserializer.deserializeString(),
      localRootRefusal: TraitHelpers.deserializeOptionStr(deserializer),
      peerDeviceId: deserializer.deserializeString(),
      peerName: TraitHelpers.deserializeOptionStr(deserializer),
      remoteRoot: deserializer.deserializeString(),
      jobs: TraitHelpers.deserializeOptionU32(deserializer),
      ignore: TraitHelpers.deserializeVectorStr(deserializer),
      lastRunUnfinished: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ProfileView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ProfileView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String name;
  final String profileId;
  final String localRoot;
  final String localRootExpanded;
  final String? localRootRefusal;
  final String peerDeviceId;
  final String? peerName;
  final String remoteRoot;
  final int? jobs;
  final List<String> ignore;
  final bool lastRunUnfinished;

  ProfileView copyWith({
    String? name,
    String? profileId,
    String? localRoot,
    String? localRootExpanded,
    String? Function()? localRootRefusal,
    String? peerDeviceId,
    String? Function()? peerName,
    String? remoteRoot,
    int? Function()? jobs,
    List<String>? ignore,
    bool? lastRunUnfinished,
  }) {
    return ProfileView(
      name: name ?? this.name,
      profileId: profileId ?? this.profileId,
      localRoot: localRoot ?? this.localRoot,
      localRootExpanded: localRootExpanded ?? this.localRootExpanded,
      localRootRefusal: localRootRefusal == null ? this.localRootRefusal : localRootRefusal(),
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      peerName: peerName == null ? this.peerName : peerName(),
      remoteRoot: remoteRoot ?? this.remoteRoot,
      jobs: jobs == null ? this.jobs : jobs(),
      ignore: ignore ?? this.ignore,
      lastRunUnfinished: lastRunUnfinished ?? this.lastRunUnfinished,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(name);
    serializer.serializeString(profileId);
    serializer.serializeString(localRoot);
    serializer.serializeString(localRootExpanded);
    TraitHelpers.serializeOptionStr(localRootRefusal, serializer);
    serializer.serializeString(peerDeviceId);
    TraitHelpers.serializeOptionStr(peerName, serializer);
    serializer.serializeString(remoteRoot);
    TraitHelpers.serializeOptionU32(jobs, serializer);
    TraitHelpers.serializeVectorStr(ignore, serializer);
    serializer.serializeBool(lastRunUnfinished);
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

    return other is ProfileView
      && name == other.name
      && profileId == other.profileId
      && localRoot == other.localRoot
      && localRootExpanded == other.localRootExpanded
      && localRootRefusal == other.localRootRefusal
      && peerDeviceId == other.peerDeviceId
      && peerName == other.peerName
      && remoteRoot == other.remoteRoot
      && jobs == other.jobs
      && listEquals(ignore, other.ignore)
      && lastRunUnfinished == other.lastRunUnfinished;
  }

  @override
  int get hashCode => Object.hash(
        name,
        profileId,
        localRoot,
        localRootExpanded,
        localRootRefusal,
        peerDeviceId,
        peerName,
        remoteRoot,
        jobs,
        ignore,
        lastRunUnfinished,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'name: $name, '
        'profileId: $profileId, '
        'localRoot: $localRoot, '
        'localRootExpanded: $localRootExpanded, '
        'localRootRefusal: $localRootRefusal, '
        'peerDeviceId: $peerDeviceId, '
        'peerName: $peerName, '
        'remoteRoot: $remoteRoot, '
        'jobs: $jobs, '
        'ignore: $ignore, '
        'lastRunUnfinished: $lastRunUnfinished'
        ')';
      return true;
    }());

    return fullString ?? 'ProfileView';
  }
}
