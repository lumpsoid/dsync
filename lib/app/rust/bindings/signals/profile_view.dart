// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ProfileView {
  const ProfileView({
    required this.name,
    required this.peerDeviceId,
    this.peerName,
    this.jobs,
    required this.ignore,
    required this.lastRun,
    required this.entries,
  });

  static ProfileView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ProfileView(
      name: deserializer.deserializeString(),
      peerDeviceId: deserializer.deserializeString(),
      peerName: TraitHelpers.deserializeOptionStr(deserializer),
      jobs: TraitHelpers.deserializeOptionU32(deserializer),
      ignore: TraitHelpers.deserializeVectorStr(deserializer),
      lastRun: LastRunViewExtension.deserialize(deserializer),
      entries: TraitHelpers.deserializeVectorEntryView(deserializer),
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
  final String peerDeviceId;
  final String? peerName;
  final int? jobs;
  final List<String> ignore;
  final LastRunView lastRun;
  final List<EntryView> entries;

  ProfileView copyWith({
    String? name,
    String? peerDeviceId,
    String? Function()? peerName,
    int? Function()? jobs,
    List<String>? ignore,
    LastRunView? lastRun,
    List<EntryView>? entries,
  }) {
    return ProfileView(
      name: name ?? this.name,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      peerName: peerName == null ? this.peerName : peerName(),
      jobs: jobs == null ? this.jobs : jobs(),
      ignore: ignore ?? this.ignore,
      lastRun: lastRun ?? this.lastRun,
      entries: entries ?? this.entries,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(name);
    serializer.serializeString(peerDeviceId);
    TraitHelpers.serializeOptionStr(peerName, serializer);
    TraitHelpers.serializeOptionU32(jobs, serializer);
    TraitHelpers.serializeVectorStr(ignore, serializer);
    lastRun.serialize(serializer);
    TraitHelpers.serializeVectorEntryView(entries, serializer);
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
      && peerDeviceId == other.peerDeviceId
      && peerName == other.peerName
      && jobs == other.jobs
      && listEquals(ignore, other.ignore)
      && lastRun == other.lastRun
      && listEquals(entries, other.entries);
  }

  @override
  int get hashCode => Object.hash(
        name,
        peerDeviceId,
        peerName,
        jobs,
        ignore,
        lastRun,
        entries,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'name: $name, '
        'peerDeviceId: $peerDeviceId, '
        'peerName: $peerName, '
        'jobs: $jobs, '
        'ignore: $ignore, '
        'lastRun: $lastRun, '
        'entries: $entries'
        ')';
      return true;
    }());

    return fullString ?? 'ProfileView';
  }
}
