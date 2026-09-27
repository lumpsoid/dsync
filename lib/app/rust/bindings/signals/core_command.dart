// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Every command the head sends, by intent. Device ids travel as their
/// text form; paths as the head holds them.
abstract class CoreCommand {
  const CoreCommand();

  void serialize(BinarySerializer serializer);

  static CoreCommand deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return CoreCommandInit.load(deserializer);
      case 1: return CoreCommandShowIdentity.load(deserializer);
      case 2: return CoreCommandRenewIdentity.load(deserializer);
      case 3: return CoreCommandShowPairing.load(deserializer);
      case 4: return CoreCommandConfirmPairing.load(deserializer);
      case 5: return CoreCommandCancelPairing.load(deserializer);
      case 6: return CoreCommandReadPairCode.load(deserializer);
      case 7: return CoreCommandAcceptPairing.load(deserializer);
      case 8: return CoreCommandListDevices.load(deserializer);
      case 9: return CoreCommandRenameDevice.load(deserializer);
      case 10: return CoreCommandRevokeDevice.load(deserializer);
      case 11: return CoreCommandGrantRoot.load(deserializer);
      case 12: return CoreCommandWithdrawGrant.load(deserializer);
      case 13: return CoreCommandSetDeviceAddress.load(deserializer);
      case 14: return CoreCommandVerifyDevice.load(deserializer);
      case 15: return CoreCommandClearVerification.load(deserializer);
      case 16: return CoreCommandProbePeer.load(deserializer);
      case 17: return CoreCommandListProfiles.load(deserializer);
      case 18: return CoreCommandSaveProfile.load(deserializer);
      case 19: return CoreCommandRenameProfile.load(deserializer);
      case 20: return CoreCommandDeleteProfile.load(deserializer);
      case 21: return CoreCommandStartRun.load(deserializer);
      case 22: return CoreCommandSteerRun.load(deserializer);
      case 23: return CoreCommandStartServe.load(deserializer);
      case 24: return CoreCommandStopServe.load(deserializer);
      case 25: return CoreCommandServeAddresses.load(deserializer);
      case 26: return CoreCommandListArchives.load(deserializer);
      case 27: return CoreCommandClearArchive.load(deserializer);
      case 28: return CoreCommandPreviewFilters.load(deserializer);
      case 29: return CoreCommandListFilterFolder.load(deserializer);
      case 30: return CoreCommandCheckIgnorePattern.load(deserializer);
      case 31: return CoreCommandCheckFolder.load(deserializer);
      default: throw Exception('Unknown variant index for CoreCommand: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static CoreCommand bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CoreCommand.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class CoreCommandInit extends CoreCommand {
  const CoreCommandInit({
    this.supportDir,
    required this.deviceName,
  }) : super();

  static CoreCommandInit load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandInit(
      supportDir: TraitHelpers.deserializeOptionStr(deserializer),
      deviceName: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String? supportDir;
  final String deviceName;

  CoreCommandInit copyWith({
    String? Function()? supportDir,
    String? deviceName,
  }) {
    return CoreCommandInit(
      supportDir: supportDir == null ? this.supportDir : supportDir(),
      deviceName: deviceName ?? this.deviceName,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    TraitHelpers.serializeOptionStr(supportDir, serializer);
    serializer.serializeString(deviceName);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandInit
      && supportDir == other.supportDir
      && deviceName == other.deviceName;
  }

  @override
  int get hashCode => Object.hash(
        supportDir,
        deviceName,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'supportDir: $supportDir, '
        'deviceName: $deviceName'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandInit';
  }
}

@immutable
class CoreCommandShowIdentity extends CoreCommand {
  const CoreCommandShowIdentity(
  ) : super();

  static CoreCommandShowIdentity load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandShowIdentity(
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

    return other is CoreCommandShowIdentity;
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

    return fullString ?? 'CoreCommandShowIdentity';
  }
}

@immutable
class CoreCommandRenewIdentity extends CoreCommand {
  const CoreCommandRenewIdentity({
    this.commonName,
  }) : super();

  static CoreCommandRenewIdentity load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandRenewIdentity(
      commonName: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String? commonName;

  CoreCommandRenewIdentity copyWith({
    String? Function()? commonName,
  }) {
    return CoreCommandRenewIdentity(
      commonName: commonName == null ? this.commonName : commonName(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    TraitHelpers.serializeOptionStr(commonName, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandRenewIdentity
      && commonName == other.commonName;
  }

  @override
  int get hashCode => commonName.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'commonName: $commonName'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandRenewIdentity';
  }
}

@immutable
class CoreCommandShowPairing extends CoreCommand {
  const CoreCommandShowPairing({
    required this.name,
    required this.bind,
    this.advertise,
    required this.servicePort,
  }) : super();

  static CoreCommandShowPairing load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandShowPairing(
      name: deserializer.deserializeString(),
      bind: deserializer.deserializeString(),
      advertise: TraitHelpers.deserializeOptionStr(deserializer),
      servicePort: deserializer.deserializeUint16(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String name;
  final String bind;
  final String? advertise;
  final int servicePort;

  CoreCommandShowPairing copyWith({
    String? name,
    String? bind,
    String? Function()? advertise,
    int? servicePort,
  }) {
    return CoreCommandShowPairing(
      name: name ?? this.name,
      bind: bind ?? this.bind,
      advertise: advertise == null ? this.advertise : advertise(),
      servicePort: servicePort ?? this.servicePort,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeString(name);
    serializer.serializeString(bind);
    TraitHelpers.serializeOptionStr(advertise, serializer);
    serializer.serializeUint16(servicePort);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandShowPairing
      && name == other.name
      && bind == other.bind
      && advertise == other.advertise
      && servicePort == other.servicePort;
  }

  @override
  int get hashCode => Object.hash(
        name,
        bind,
        advertise,
        servicePort,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'name: $name, '
        'bind: $bind, '
        'advertise: $advertise, '
        'servicePort: $servicePort'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandShowPairing';
  }
}

@immutable
class CoreCommandConfirmPairing extends CoreCommand {
  const CoreCommandConfirmPairing({
    required this.session,
    required this.accept,
  }) : super();

  static CoreCommandConfirmPairing load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandConfirmPairing(
      session: deserializer.deserializeUint64(),
      accept: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 session;
  final bool accept;

  CoreCommandConfirmPairing copyWith({
    Uint64? session,
    bool? accept,
  }) {
    return CoreCommandConfirmPairing(
      session: session ?? this.session,
      accept: accept ?? this.accept,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.serializeUint64(session);
    serializer.serializeBool(accept);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandConfirmPairing
      && session == other.session
      && accept == other.accept;
  }

  @override
  int get hashCode => Object.hash(
        session,
        accept,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'session: $session, '
        'accept: $accept'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandConfirmPairing';
  }
}

@immutable
class CoreCommandCancelPairing extends CoreCommand {
  const CoreCommandCancelPairing({
    required this.session,
  }) : super();

  static CoreCommandCancelPairing load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandCancelPairing(
      session: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 session;

  CoreCommandCancelPairing copyWith({
    Uint64? session,
  }) {
    return CoreCommandCancelPairing(
      session: session ?? this.session,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.serializeUint64(session);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandCancelPairing
      && session == other.session;
  }

  @override
  int get hashCode => session.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'session: $session'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandCancelPairing';
  }
}

@immutable
class CoreCommandReadPairCode extends CoreCommand {
  const CoreCommandReadPairCode({
    required this.text,
  }) : super();

  static CoreCommandReadPairCode load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandReadPairCode(
      text: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String text;

  CoreCommandReadPairCode copyWith({
    String? text,
  }) {
    return CoreCommandReadPairCode(
      text: text ?? this.text,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(6);
    serializer.serializeString(text);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandReadPairCode
      && text == other.text;
  }

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'text: $text'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandReadPairCode';
  }
}

@immutable
class CoreCommandAcceptPairing extends CoreCommand {
  const CoreCommandAcceptPairing({
    required this.code,
    required this.name,
  }) : super();

  static CoreCommandAcceptPairing load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandAcceptPairing(
      code: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String code;
  final String name;

  CoreCommandAcceptPairing copyWith({
    String? code,
    String? name,
  }) {
    return CoreCommandAcceptPairing(
      code: code ?? this.code,
      name: name ?? this.name,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(7);
    serializer.serializeString(code);
    serializer.serializeString(name);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandAcceptPairing
      && code == other.code
      && name == other.name;
  }

  @override
  int get hashCode => Object.hash(
        code,
        name,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'code: $code, '
        'name: $name'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandAcceptPairing';
  }
}

@immutable
class CoreCommandListDevices extends CoreCommand {
  const CoreCommandListDevices(
  ) : super();

  static CoreCommandListDevices load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandListDevices(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(8);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandListDevices;
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

    return fullString ?? 'CoreCommandListDevices';
  }
}

@immutable
class CoreCommandRenameDevice extends CoreCommand {
  const CoreCommandRenameDevice({
    required this.deviceId,
    required this.name,
  }) : super();

  static CoreCommandRenameDevice load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandRenameDevice(
      deviceId: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String name;

  CoreCommandRenameDevice copyWith({
    String? deviceId,
    String? name,
  }) {
    return CoreCommandRenameDevice(
      deviceId: deviceId ?? this.deviceId,
      name: name ?? this.name,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(9);
    serializer.serializeString(deviceId);
    serializer.serializeString(name);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandRenameDevice
      && deviceId == other.deviceId
      && name == other.name;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        name,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId, '
        'name: $name'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandRenameDevice';
  }
}

@immutable
class CoreCommandRevokeDevice extends CoreCommand {
  const CoreCommandRevokeDevice({
    required this.deviceId,
  }) : super();

  static CoreCommandRevokeDevice load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandRevokeDevice(
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;

  CoreCommandRevokeDevice copyWith({
    String? deviceId,
  }) {
    return CoreCommandRevokeDevice(
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(10);
    serializer.serializeString(deviceId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandRevokeDevice
      && deviceId == other.deviceId;
  }

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandRevokeDevice';
  }
}

@immutable
class CoreCommandGrantRoot extends CoreCommand {
  const CoreCommandGrantRoot({
    required this.deviceId,
    required this.path,
  }) : super();

  static CoreCommandGrantRoot load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandGrantRoot(
      deviceId: deserializer.deserializeString(),
      path: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String path;

  CoreCommandGrantRoot copyWith({
    String? deviceId,
    String? path,
  }) {
    return CoreCommandGrantRoot(
      deviceId: deviceId ?? this.deviceId,
      path: path ?? this.path,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(11);
    serializer.serializeString(deviceId);
    serializer.serializeString(path);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandGrantRoot
      && deviceId == other.deviceId
      && path == other.path;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        path,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId, '
        'path: $path'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandGrantRoot';
  }
}

@immutable
class CoreCommandWithdrawGrant extends CoreCommand {
  const CoreCommandWithdrawGrant({
    required this.deviceId,
    required this.root,
  }) : super();

  static CoreCommandWithdrawGrant load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandWithdrawGrant(
      deviceId: deserializer.deserializeString(),
      root: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String root;

  CoreCommandWithdrawGrant copyWith({
    String? deviceId,
    String? root,
  }) {
    return CoreCommandWithdrawGrant(
      deviceId: deviceId ?? this.deviceId,
      root: root ?? this.root,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(12);
    serializer.serializeString(deviceId);
    serializer.serializeString(root);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandWithdrawGrant
      && deviceId == other.deviceId
      && root == other.root;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        root,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId, '
        'root: $root'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandWithdrawGrant';
  }
}

@immutable
class CoreCommandSetDeviceAddress extends CoreCommand {
  const CoreCommandSetDeviceAddress({
    required this.deviceId,
    required this.address,
  }) : super();

  static CoreCommandSetDeviceAddress load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandSetDeviceAddress(
      deviceId: deserializer.deserializeString(),
      address: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String address;

  CoreCommandSetDeviceAddress copyWith({
    String? deviceId,
    String? address,
  }) {
    return CoreCommandSetDeviceAddress(
      deviceId: deviceId ?? this.deviceId,
      address: address ?? this.address,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(13);
    serializer.serializeString(deviceId);
    serializer.serializeString(address);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandSetDeviceAddress
      && deviceId == other.deviceId
      && address == other.address;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        address,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId, '
        'address: $address'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandSetDeviceAddress';
  }
}

@immutable
class CoreCommandVerifyDevice extends CoreCommand {
  const CoreCommandVerifyDevice({
    required this.deviceId,
  }) : super();

  static CoreCommandVerifyDevice load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandVerifyDevice(
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;

  CoreCommandVerifyDevice copyWith({
    String? deviceId,
  }) {
    return CoreCommandVerifyDevice(
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(14);
    serializer.serializeString(deviceId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandVerifyDevice
      && deviceId == other.deviceId;
  }

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandVerifyDevice';
  }
}

@immutable
class CoreCommandClearVerification extends CoreCommand {
  const CoreCommandClearVerification({
    required this.deviceId,
  }) : super();

  static CoreCommandClearVerification load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandClearVerification(
      deviceId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;

  CoreCommandClearVerification copyWith({
    String? deviceId,
  }) {
    return CoreCommandClearVerification(
      deviceId: deviceId ?? this.deviceId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(15);
    serializer.serializeString(deviceId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandClearVerification
      && deviceId == other.deviceId;
  }

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandClearVerification';
  }
}

@immutable
class CoreCommandProbePeer extends CoreCommand {
  const CoreCommandProbePeer({
    required this.deviceId,
    this.address,
  }) : super();

  static CoreCommandProbePeer load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandProbePeer(
      deviceId: deserializer.deserializeString(),
      address: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String deviceId;
  final String? address;

  CoreCommandProbePeer copyWith({
    String? deviceId,
    String? Function()? address,
  }) {
    return CoreCommandProbePeer(
      deviceId: deviceId ?? this.deviceId,
      address: address == null ? this.address : address(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(16);
    serializer.serializeString(deviceId);
    TraitHelpers.serializeOptionStr(address, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandProbePeer
      && deviceId == other.deviceId
      && address == other.address;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        address,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'deviceId: $deviceId, '
        'address: $address'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandProbePeer';
  }
}

@immutable
class CoreCommandListProfiles extends CoreCommand {
  const CoreCommandListProfiles(
  ) : super();

  static CoreCommandListProfiles load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandListProfiles(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(17);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandListProfiles;
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

    return fullString ?? 'CoreCommandListProfiles';
  }
}

@immutable
class CoreCommandSaveProfile extends CoreCommand {
  const CoreCommandSaveProfile({
    required this.name,
    required this.draft,
  }) : super();

  static CoreCommandSaveProfile load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandSaveProfile(
      name: deserializer.deserializeString(),
      draft: ProfileDraft.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String name;
  final ProfileDraft draft;

  CoreCommandSaveProfile copyWith({
    String? name,
    ProfileDraft? draft,
  }) {
    return CoreCommandSaveProfile(
      name: name ?? this.name,
      draft: draft ?? this.draft,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(18);
    serializer.serializeString(name);
    draft.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandSaveProfile
      && name == other.name
      && draft == other.draft;
  }

  @override
  int get hashCode => Object.hash(
        name,
        draft,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'name: $name, '
        'draft: $draft'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandSaveProfile';
  }
}

@immutable
class CoreCommandRenameProfile extends CoreCommand {
  const CoreCommandRenameProfile({
    required this.from,
    required this.to,
  }) : super();

  static CoreCommandRenameProfile load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandRenameProfile(
      from: deserializer.deserializeString(),
      to: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String from;
  final String to;

  CoreCommandRenameProfile copyWith({
    String? from,
    String? to,
  }) {
    return CoreCommandRenameProfile(
      from: from ?? this.from,
      to: to ?? this.to,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(19);
    serializer.serializeString(from);
    serializer.serializeString(to);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandRenameProfile
      && from == other.from
      && to == other.to;
  }

  @override
  int get hashCode => Object.hash(
        from,
        to,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'from: $from, '
        'to: $to'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandRenameProfile';
  }
}

@immutable
class CoreCommandDeleteProfile extends CoreCommand {
  const CoreCommandDeleteProfile({
    required this.name,
  }) : super();

  static CoreCommandDeleteProfile load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandDeleteProfile(
      name: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String name;

  CoreCommandDeleteProfile copyWith({
    String? name,
  }) {
    return CoreCommandDeleteProfile(
      name: name ?? this.name,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(20);
    serializer.serializeString(name);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandDeleteProfile
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

    return fullString ?? 'CoreCommandDeleteProfile';
  }
}

@immutable
class CoreCommandStartRun extends CoreCommand {
  const CoreCommandStartRun({
    required this.target,
    required this.dryRun,
    this.address,
  }) : super();

  static CoreCommandStartRun load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandStartRun(
      target: RunTarget.deserialize(deserializer),
      dryRun: deserializer.deserializeBool(),
      address: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final RunTarget target;
  final bool dryRun;
  final String? address;

  CoreCommandStartRun copyWith({
    RunTarget? target,
    bool? dryRun,
    String? Function()? address,
  }) {
    return CoreCommandStartRun(
      target: target ?? this.target,
      dryRun: dryRun ?? this.dryRun,
      address: address == null ? this.address : address(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(21);
    target.serialize(serializer);
    serializer.serializeBool(dryRun);
    TraitHelpers.serializeOptionStr(address, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandStartRun
      && target == other.target
      && dryRun == other.dryRun
      && address == other.address;
  }

  @override
  int get hashCode => Object.hash(
        target,
        dryRun,
        address,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'target: $target, '
        'dryRun: $dryRun, '
        'address: $address'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandStartRun';
  }
}

@immutable
class CoreCommandSteerRun extends CoreCommand {
  const CoreCommandSteerRun({
    required this.session,
    required this.intent,
  }) : super();

  static CoreCommandSteerRun load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandSteerRun(
      session: deserializer.deserializeUint64(),
      intent: RunIntent.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 session;
  final RunIntent intent;

  CoreCommandSteerRun copyWith({
    Uint64? session,
    RunIntent? intent,
  }) {
    return CoreCommandSteerRun(
      session: session ?? this.session,
      intent: intent ?? this.intent,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(22);
    serializer.serializeUint64(session);
    intent.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandSteerRun
      && session == other.session
      && intent == other.intent;
  }

  @override
  int get hashCode => Object.hash(
        session,
        intent,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'session: $session, '
        'intent: $intent'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandSteerRun';
  }
}

@immutable
class CoreCommandStartServe extends CoreCommand {
  const CoreCommandStartServe({
    required this.bind,
    required this.port,
  }) : super();

  static CoreCommandStartServe load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandStartServe(
      bind: deserializer.deserializeString(),
      port: deserializer.deserializeUint16(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String bind;
  final int port;

  CoreCommandStartServe copyWith({
    String? bind,
    int? port,
  }) {
    return CoreCommandStartServe(
      bind: bind ?? this.bind,
      port: port ?? this.port,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(23);
    serializer.serializeString(bind);
    serializer.serializeUint16(port);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandStartServe
      && bind == other.bind
      && port == other.port;
  }

  @override
  int get hashCode => Object.hash(
        bind,
        port,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'bind: $bind, '
        'port: $port'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandStartServe';
  }
}

@immutable
class CoreCommandStopServe extends CoreCommand {
  const CoreCommandStopServe({
    required this.session,
  }) : super();

  static CoreCommandStopServe load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandStopServe(
      session: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final Uint64 session;

  CoreCommandStopServe copyWith({
    Uint64? session,
  }) {
    return CoreCommandStopServe(
      session: session ?? this.session,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(24);
    serializer.serializeUint64(session);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandStopServe
      && session == other.session;
  }

  @override
  int get hashCode => session.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'session: $session'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandStopServe';
  }
}

@immutable
class CoreCommandServeAddresses extends CoreCommand {
  const CoreCommandServeAddresses(
  ) : super();

  static CoreCommandServeAddresses load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandServeAddresses(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(25);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandServeAddresses;
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

    return fullString ?? 'CoreCommandServeAddresses';
  }
}

@immutable
class CoreCommandListArchives extends CoreCommand {
  const CoreCommandListArchives(
  ) : super();

  static CoreCommandListArchives load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandListArchives(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(26);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandListArchives;
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

    return fullString ?? 'CoreCommandListArchives';
  }
}

@immutable
class CoreCommandClearArchive extends CoreCommand {
  const CoreCommandClearArchive({
    required this.entryId,
  }) : super();

  static CoreCommandClearArchive load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandClearArchive(
      entryId: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String entryId;

  CoreCommandClearArchive copyWith({
    String? entryId,
  }) {
    return CoreCommandClearArchive(
      entryId: entryId ?? this.entryId,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(27);
    serializer.serializeString(entryId);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandClearArchive
      && entryId == other.entryId;
  }

  @override
  int get hashCode => entryId.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'entryId: $entryId'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandClearArchive';
  }
}

@immutable
class CoreCommandPreviewFilters extends CoreCommand {
  const CoreCommandPreviewFilters({
    required this.root,
    required this.ignore,
  }) : super();

  static CoreCommandPreviewFilters load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandPreviewFilters(
      root: deserializer.deserializeString(),
      ignore: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String root;
  final List<String> ignore;

  CoreCommandPreviewFilters copyWith({
    String? root,
    List<String>? ignore,
  }) {
    return CoreCommandPreviewFilters(
      root: root ?? this.root,
      ignore: ignore ?? this.ignore,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(28);
    serializer.serializeString(root);
    TraitHelpers.serializeVectorStr(ignore, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandPreviewFilters
      && root == other.root
      && listEquals(ignore, other.ignore);
  }

  @override
  int get hashCode => Object.hash(
        root,
        ignore,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'root: $root, '
        'ignore: $ignore'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandPreviewFilters';
  }
}

@immutable
class CoreCommandListFilterFolder extends CoreCommand {
  const CoreCommandListFilterFolder({
    required this.root,
    this.folder,
    required this.ignore,
  }) : super();

  static CoreCommandListFilterFolder load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandListFilterFolder(
      root: deserializer.deserializeString(),
      folder: TraitHelpers.deserializeOptionStr(deserializer),
      ignore: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String root;
  final String? folder;
  final List<String> ignore;

  CoreCommandListFilterFolder copyWith({
    String? root,
    String? Function()? folder,
    List<String>? ignore,
  }) {
    return CoreCommandListFilterFolder(
      root: root ?? this.root,
      folder: folder == null ? this.folder : folder(),
      ignore: ignore ?? this.ignore,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(29);
    serializer.serializeString(root);
    TraitHelpers.serializeOptionStr(folder, serializer);
    TraitHelpers.serializeVectorStr(ignore, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandListFilterFolder
      && root == other.root
      && folder == other.folder
      && listEquals(ignore, other.ignore);
  }

  @override
  int get hashCode => Object.hash(
        root,
        folder,
        ignore,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'root: $root, '
        'folder: $folder, '
        'ignore: $ignore'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandListFilterFolder';
  }
}

@immutable
class CoreCommandCheckIgnorePattern extends CoreCommand {
  const CoreCommandCheckIgnorePattern({
    required this.pattern,
  }) : super();

  static CoreCommandCheckIgnorePattern load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandCheckIgnorePattern(
      pattern: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String pattern;

  CoreCommandCheckIgnorePattern copyWith({
    String? pattern,
  }) {
    return CoreCommandCheckIgnorePattern(
      pattern: pattern ?? this.pattern,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(30);
    serializer.serializeString(pattern);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandCheckIgnorePattern
      && pattern == other.pattern;
  }

  @override
  int get hashCode => pattern.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'pattern: $pattern'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandCheckIgnorePattern';
  }
}

@immutable
class CoreCommandCheckFolder extends CoreCommand {
  const CoreCommandCheckFolder({
    required this.path,
    required this.kind,
  }) : super();

  static CoreCommandCheckFolder load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CoreCommandCheckFolder(
      path: deserializer.deserializeString(),
      kind: RootKindViewExtension.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String path;
  final RootKindView kind;

  CoreCommandCheckFolder copyWith({
    String? path,
    RootKindView? kind,
  }) {
    return CoreCommandCheckFolder(
      path: path ?? this.path,
      kind: kind ?? this.kind,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(31);
    serializer.serializeString(path);
    kind.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is CoreCommandCheckFolder
      && path == other.path
      && kind == other.kind;
  }

  @override
  int get hashCode => Object.hash(
        path,
        kind,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'kind: $kind'
        ')';
      return true;
    }());

    return fullString ?? 'CoreCommandCheckFolder';
  }
}
