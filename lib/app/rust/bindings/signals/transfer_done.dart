// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The transfer is over and every file is on disk. The metrics cover the
/// span from the end of the handshake to the last file on disk.
@immutable
class TransferDone {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _transferDoneStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<TransferDone>? latestRustSignal = null;

  const TransferDone({
    required this.peerDeviceId,
    required this.files,
    required this.bytes,
    required this.wallSeconds,
    required this.mibPerSecond,
    required this.filesPerSecond,
    this.cpuSeconds,
    this.cpuMsPerMib,
  });

  static TransferDone deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TransferDone(
      peerDeviceId: deserializer.deserializeString(),
      files: deserializer.deserializeUint64(),
      bytes: deserializer.deserializeUint64(),
      wallSeconds: deserializer.deserializeFloat64(),
      mibPerSecond: deserializer.deserializeFloat64(),
      filesPerSecond: deserializer.deserializeFloat64(),
      cpuSeconds: TraitHelpers.deserializeOptionF64(deserializer),
      cpuMsPerMib: TraitHelpers.deserializeOptionF64(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TransferDone bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TransferDone.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String peerDeviceId;
  final Uint64 files;
  final Uint64 bytes;
  final double wallSeconds;
  final double mibPerSecond;
  final double filesPerSecond;
  final double? cpuSeconds;
  final double? cpuMsPerMib;

  TransferDone copyWith({
    String? peerDeviceId,
    Uint64? files,
    Uint64? bytes,
    double? wallSeconds,
    double? mibPerSecond,
    double? filesPerSecond,
    double? Function()? cpuSeconds,
    double? Function()? cpuMsPerMib,
  }) {
    return TransferDone(
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      files: files ?? this.files,
      bytes: bytes ?? this.bytes,
      wallSeconds: wallSeconds ?? this.wallSeconds,
      mibPerSecond: mibPerSecond ?? this.mibPerSecond,
      filesPerSecond: filesPerSecond ?? this.filesPerSecond,
      cpuSeconds: cpuSeconds == null ? this.cpuSeconds : cpuSeconds(),
      cpuMsPerMib: cpuMsPerMib == null ? this.cpuMsPerMib : cpuMsPerMib(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(peerDeviceId);
    serializer.serializeUint64(files);
    serializer.serializeUint64(bytes);
    serializer.serializeFloat64(wallSeconds);
    serializer.serializeFloat64(mibPerSecond);
    serializer.serializeFloat64(filesPerSecond);
    TraitHelpers.serializeOptionF64(cpuSeconds, serializer);
    TraitHelpers.serializeOptionF64(cpuMsPerMib, serializer);
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

    return other is TransferDone
      && peerDeviceId == other.peerDeviceId
      && files == other.files
      && bytes == other.bytes
      && wallSeconds == other.wallSeconds
      && mibPerSecond == other.mibPerSecond
      && filesPerSecond == other.filesPerSecond
      && cpuSeconds == other.cpuSeconds
      && cpuMsPerMib == other.cpuMsPerMib;
  }

  @override
  int get hashCode => Object.hash(
        peerDeviceId,
        files,
        bytes,
        wallSeconds,
        mibPerSecond,
        filesPerSecond,
        cpuSeconds,
        cpuMsPerMib,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'peerDeviceId: $peerDeviceId, '
        'files: $files, '
        'bytes: $bytes, '
        'wallSeconds: $wallSeconds, '
        'mibPerSecond: $mibPerSecond, '
        'filesPerSecond: $filesPerSecond, '
        'cpuSeconds: $cpuSeconds, '
        'cpuMsPerMib: $cpuMsPerMib'
        ')';
      return true;
    }());

    return fullString ?? 'TransferDone';
  }
}

final _transferDoneStreamController =
    StreamController<RustSignalPack<TransferDone>>();
