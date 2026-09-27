// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The head's profile: each entry's `local_root` on this device synced
/// with its `remote_root` on the paired device `peer_device_id`.
@immutable
class ProfileDraft {
  const ProfileDraft({
    required this.peerDeviceId,
    required this.entries,
    this.jobs,
    required this.ignore,
  });

  static ProfileDraft deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProfileDraft(
      peerDeviceId: deserializer.deserializeString(),
      entries: TraitHelpers.deserializeVectorEntryDraft(deserializer),
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

  final String peerDeviceId;
  final List<EntryDraft> entries;
  final int? jobs;
  final List<String> ignore;

  ProfileDraft copyWith({
    String? peerDeviceId,
    List<EntryDraft>? entries,
    int? Function()? jobs,
    List<String>? ignore,
  }) {
    return ProfileDraft(
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      entries: entries ?? this.entries,
      jobs: jobs == null ? this.jobs : jobs(),
      ignore: ignore ?? this.ignore,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(peerDeviceId);
    TraitHelpers.serializeVectorEntryDraft(entries, serializer);
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
      && peerDeviceId == other.peerDeviceId
      && listEquals(entries, other.entries)
      && jobs == other.jobs
      && listEquals(ignore, other.ignore);
  }

  @override
  int get hashCode => Object.hash(
        peerDeviceId,
        entries,
        jobs,
        ignore,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'peerDeviceId: $peerDeviceId, '
        'entries: $entries, '
        'jobs: $jobs, '
        'ignore: $ignore'
        ')';
      return true;
    }());

    return fullString ?? 'ProfileDraft';
  }
}
