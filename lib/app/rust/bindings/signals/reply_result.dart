// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What a command returned. `Failed` carries the core's own message.
abstract class ReplyResult {
  const ReplyResult();

  void serialize(BinarySerializer serializer);

  static ReplyResult deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ReplyResultFailed.load(deserializer);
      case 1: return ReplyResultDone.load(deserializer);
      case 2: return ReplyResultIdentity.load(deserializer);
      case 3: return ReplyResultPairingShown.load(deserializer);
      case 4: return ReplyResultPairCode.load(deserializer);
      case 5: return ReplyResultDevice.load(deserializer);
      case 6: return ReplyResultDevices.load(deserializer);
      case 7: return ReplyResultPeerProbed.load(deserializer);
      case 8: return ReplyResultProfiles.load(deserializer);
      case 9: return ReplyResultRunStarted.load(deserializer);
      case 10: return ReplyResultServeStarted.load(deserializer);
      case 11: return ReplyResultAddresses.load(deserializer);
      case 12: return ReplyResultArchives.load(deserializer);
      case 13: return ReplyResultFilterPreview.load(deserializer);
      case 14: return ReplyResultFilterFolder.load(deserializer);
      case 15: return ReplyResultFolderChecked.load(deserializer);
      case 16: return ReplyResultScanProbe.load(deserializer);
      default: throw Exception('Unknown variant index for ReplyResult: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ReplyResult bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ReplyResult.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class ReplyResultFailed extends ReplyResult {
  const ReplyResultFailed({
    required this.message,
  }) : super();

  static ReplyResultFailed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultFailed(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  ReplyResultFailed copyWith({
    String? message,
  }) {
    return ReplyResultFailed(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultFailed
      && message == other.message;
  }

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'ReplyResultFailed';
  }
}

@immutable
class ReplyResultDone extends ReplyResult {
  const ReplyResultDone(
  ) : super();

  static ReplyResultDone load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultDone(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultDone;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'ReplyResultDone';
  }
}

@immutable
class ReplyResultIdentity extends ReplyResult {
  const ReplyResultIdentity({
    required this.value,
  }) : super();

  static ReplyResultIdentity load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultIdentity(
      value: IdentityView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final IdentityView value;

  ReplyResultIdentity copyWith({
    IdentityView? value,
  }) {
    return ReplyResultIdentity(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultIdentity
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

    return fullString ?? 'ReplyResultIdentity';
  }
}

@immutable
class ReplyResultPairingShown extends ReplyResult {
  const ReplyResultPairingShown({
    required this.value,
  }) : super();

  static ReplyResultPairingShown load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultPairingShown(
      value: PairingShownView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final PairingShownView value;

  ReplyResultPairingShown copyWith({
    PairingShownView? value,
  }) {
    return ReplyResultPairingShown(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultPairingShown
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

    return fullString ?? 'ReplyResultPairingShown';
  }
}

@immutable
class ReplyResultPairCode extends ReplyResult {
  const ReplyResultPairCode({
    required this.value,
  }) : super();

  static ReplyResultPairCode load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultPairCode(
      value: PairCodeView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final PairCodeView value;

  ReplyResultPairCode copyWith({
    PairCodeView? value,
  }) {
    return ReplyResultPairCode(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultPairCode
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

    return fullString ?? 'ReplyResultPairCode';
  }
}

@immutable
class ReplyResultDevice extends ReplyResult {
  const ReplyResultDevice({
    required this.value,
  }) : super();

  static ReplyResultDevice load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultDevice(
      value: DeviceView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final DeviceView value;

  ReplyResultDevice copyWith({
    DeviceView? value,
  }) {
    return ReplyResultDevice(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultDevice
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

    return fullString ?? 'ReplyResultDevice';
  }
}

@immutable
class ReplyResultDevices extends ReplyResult {
  const ReplyResultDevices({
    required this.value,
  }) : super();

  static ReplyResultDevices load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultDevices(
      value: TraitHelpers.deserializeVectorDeviceView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<DeviceView> value;

  ReplyResultDevices copyWith({
    List<DeviceView>? value,
  }) {
    return ReplyResultDevices(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    TraitHelpers.serializeVectorDeviceView(value, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultDevices
      && listEquals(value, other.value);
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

    return fullString ?? 'ReplyResultDevices';
  }
}

@immutable
class ReplyResultPeerProbed extends ReplyResult {
  const ReplyResultPeerProbed({
    required this.value,
  }) : super();

  static ReplyResultPeerProbed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultPeerProbed(
      value: ProbeOutcome.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ProbeOutcome value;

  ReplyResultPeerProbed copyWith({
    ProbeOutcome? value,
  }) {
    return ReplyResultPeerProbed(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultPeerProbed
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

    return fullString ?? 'ReplyResultPeerProbed';
  }
}

@immutable
class ReplyResultProfiles extends ReplyResult {
  const ReplyResultProfiles({
    required this.value,
  }) : super();

  static ReplyResultProfiles load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultProfiles(
      value: TraitHelpers.deserializeVectorProfileEntry(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<ProfileEntry> value;

  ReplyResultProfiles copyWith({
    List<ProfileEntry>? value,
  }) {
    return ReplyResultProfiles(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    TraitHelpers.serializeVectorProfileEntry(value, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultProfiles
      && listEquals(value, other.value);
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

    return fullString ?? 'ReplyResultProfiles';
  }
}

@immutable
class ReplyResultRunStarted extends ReplyResult {
  const ReplyResultRunStarted({
    required this.value,
  }) : super();

  static ReplyResultRunStarted load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultRunStarted(
      value: RunStartedView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RunStartedView value;

  ReplyResultRunStarted copyWith({
    RunStartedView? value,
  }) {
    return ReplyResultRunStarted(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(9);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultRunStarted
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

    return fullString ?? 'ReplyResultRunStarted';
  }
}

@immutable
class ReplyResultServeStarted extends ReplyResult {
  const ReplyResultServeStarted({
    required this.value,
  }) : super();

  static ReplyResultServeStarted load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultServeStarted(
      value: ServeStartedView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ServeStartedView value;

  ReplyResultServeStarted copyWith({
    ServeStartedView? value,
  }) {
    return ReplyResultServeStarted(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultServeStarted
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

    return fullString ?? 'ReplyResultServeStarted';
  }
}

@immutable
class ReplyResultAddresses extends ReplyResult {
  const ReplyResultAddresses({
    required this.value,
  }) : super();

  static ReplyResultAddresses load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultAddresses(
      value: AddressesView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final AddressesView value;

  ReplyResultAddresses copyWith({
    AddressesView? value,
  }) {
    return ReplyResultAddresses(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(11);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultAddresses
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

    return fullString ?? 'ReplyResultAddresses';
  }
}

@immutable
class ReplyResultArchives extends ReplyResult {
  const ReplyResultArchives({
    required this.value,
  }) : super();

  static ReplyResultArchives load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultArchives(
      value: TraitHelpers.deserializeVectorArchiveView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<ArchiveView> value;

  ReplyResultArchives copyWith({
    List<ArchiveView>? value,
  }) {
    return ReplyResultArchives(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(12);
    TraitHelpers.serializeVectorArchiveView(value, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultArchives
      && listEquals(value, other.value);
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

    return fullString ?? 'ReplyResultArchives';
  }
}

@immutable
class ReplyResultFilterPreview extends ReplyResult {
  const ReplyResultFilterPreview({
    required this.value,
  }) : super();

  static ReplyResultFilterPreview load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultFilterPreview(
      value: FilterPreviewView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final FilterPreviewView value;

  ReplyResultFilterPreview copyWith({
    FilterPreviewView? value,
  }) {
    return ReplyResultFilterPreview(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(13);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultFilterPreview
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

    return fullString ?? 'ReplyResultFilterPreview';
  }
}

@immutable
class ReplyResultFilterFolder extends ReplyResult {
  const ReplyResultFilterFolder({
    required this.value,
  }) : super();

  static ReplyResultFilterFolder load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultFilterFolder(
      value: TraitHelpers.deserializeVectorFilterRowView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<FilterRowView> value;

  ReplyResultFilterFolder copyWith({
    List<FilterRowView>? value,
  }) {
    return ReplyResultFilterFolder(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(14);
    TraitHelpers.serializeVectorFilterRowView(value, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultFilterFolder
      && listEquals(value, other.value);
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

    return fullString ?? 'ReplyResultFilterFolder';
  }
}

@immutable
class ReplyResultFolderChecked extends ReplyResult {
  const ReplyResultFolderChecked({
    this.refusal,
  }) : super();

  static ReplyResultFolderChecked load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultFolderChecked(
      refusal: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String? refusal;

  ReplyResultFolderChecked copyWith({
    String? Function()? refusal,
  }) {
    return ReplyResultFolderChecked(
      refusal: refusal == null ? this.refusal : refusal(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(15);
    TraitHelpers.serializeOptionStr(refusal, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultFolderChecked
      && refusal == other.refusal;
  }

  @override
  int get hashCode => refusal.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'refusal: $refusal'
        ')';
      return true;
    }());

    return fullString ?? 'ReplyResultFolderChecked';
  }
}

@immutable
class ReplyResultScanProbe extends ReplyResult {
  const ReplyResultScanProbe({
    required this.value,
  }) : super();

  static ReplyResultScanProbe load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ReplyResultScanProbe(
      value: ScanProbeView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final ScanProbeView value;

  ReplyResultScanProbe copyWith({
    ScanProbeView? value,
  }) {
    return ReplyResultScanProbe(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(16);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ReplyResultScanProbe
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

    return fullString ?? 'ReplyResultScanProbe';
  }
}
