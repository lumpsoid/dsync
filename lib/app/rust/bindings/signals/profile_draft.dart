// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The head's profile: this device's `local_root` synced with
/// `remote_root` on the paired device `peer_device_id`.
@immutable
class ProfileDraft {
  const ProfileDraft({
    required this.localRoot,
    required this.peerDeviceId,
    required this.remoteRoot,
    this.jobs,
    required this.ignore,
  });

  static ProfileDraft deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProfileDraft(
      localRoot: deserializer.deserializeString(),
      peerDeviceId: deserializer.deserializeString(),
      remoteRoot: deserializer.deserializeString(),
      jobs: TraitHelpers.deserializeOptionU32(deserializer),
      ignore: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ProfileDraft bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ProfileDraft.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String localRoot;
  final String peerDeviceId;
  final String remoteRoot;
  final int? jobs;
  final List<String> ignore;

  ProfileDraft copyWith({
    String? localRoot,
    String? peerDeviceId,
    String? remoteRoot,
    int? Function()? jobs,
    List<String>? ignore,
  }) {
    return ProfileDraft(
      localRoot: localRoot ?? this.localRoot,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      remoteRoot: remoteRoot ?? this.remoteRoot,
      jobs: jobs == null ? this.jobs : jobs(),
      ignore: ignore ?? this.ignore,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(localRoot);
    serializer.serializeString(peerDeviceId);
    serializer.serializeString(remoteRoot);
    TraitHelpers.serializeOptionU32(jobs, serializer);
    TraitHelpers.serializeVectorStr(ignore, serializer);
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

    return other is ProfileDraft
      && localRoot == other.localRoot
      && peerDeviceId == other.peerDeviceId
      && remoteRoot == other.remoteRoot
      && jobs == other.jobs
      && listEquals(ignore, other.ignore);
  }

  @override
  int get hashCode => Object.hash(
        localRoot,
        peerDeviceId,
        remoteRoot,
        jobs,
        ignore,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'localRoot: $localRoot, '
        'peerDeviceId: $peerDeviceId, '
        'remoteRoot: $remoteRoot, '
        'jobs: $jobs, '
        'ignore: $ignore'
        ')';
      return true;
    }());

    return fullString ?? 'ProfileDraft';
  }
}
