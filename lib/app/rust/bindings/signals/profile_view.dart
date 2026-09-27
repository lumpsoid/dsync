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
    required this.lastRunUnfinished,
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
      lastRunUnfinished: deserializer.deserializeBool(),
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
  final bool lastRunUnfinished;
  final List<EntryView> entries;

  ProfileView copyWith({
    String? name,
    String? peerDeviceId,
    String? Function()? peerName,
    int? Function()? jobs,
    List<String>? ignore,
    bool? lastRunUnfinished,
    List<EntryView>? entries,
  }) {
    return ProfileView(
      name: name ?? this.name,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      peerName: peerName == null ? this.peerName : peerName(),
      jobs: jobs == null ? this.jobs : jobs(),
      ignore: ignore ?? this.ignore,
      lastRunUnfinished: lastRunUnfinished ?? this.lastRunUnfinished,
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
    serializer.serializeBool(lastRunUnfinished);
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
      && lastRunUnfinished == other.lastRunUnfinished
      && listEquals(entries, other.entries);
  }

  @override
  int get hashCode => Object.hash(
        name,
        peerDeviceId,
        peerName,
        jobs,
        ignore,
        lastRunUnfinished,
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
        'lastRunUnfinished: $lastRunUnfinished, '
        'entries: $entries'
        ')';
      return true;
    }());

    return fullString ?? 'ProfileView';
  }
}
