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
    this.writerCpuSeconds,
    this.otherCpuSeconds,
    required this.writers,
    required this.writersBusy,
    required this.queueWaitMeanMs,
    required this.queueWaitTotalSeconds,
    required this.stages,
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
      writerCpuSeconds: TraitHelpers.deserializeOptionF64(deserializer),
      otherCpuSeconds: TraitHelpers.deserializeOptionF64(deserializer),
      writers: deserializer.deserializeUint32(),
      writersBusy: deserializer.deserializeFloat64(),
      queueWaitMeanMs: deserializer.deserializeFloat64(),
      queueWaitTotalSeconds: deserializer.deserializeFloat64(),
      stages: TraitHelpers.deserializeVectorStageTiming(deserializer),
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
  final double? writerCpuSeconds;
  final double? otherCpuSeconds;
  final int writers;
  final double writersBusy;
  final double queueWaitMeanMs;
  final double queueWaitTotalSeconds;
  final List<StageTiming> stages;

  TransferDone copyWith({
    String? peerDeviceId,
    Uint64? files,
    Uint64? bytes,
    double? wallSeconds,
    double? mibPerSecond,
    double? filesPerSecond,
    double? Function()? cpuSeconds,
    double? Function()? cpuMsPerMib,
    double? Function()? writerCpuSeconds,
    double? Function()? otherCpuSeconds,
    int? writers,
    double? writersBusy,
    double? queueWaitMeanMs,
    double? queueWaitTotalSeconds,
    List<StageTiming>? stages,
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
      writerCpuSeconds: writerCpuSeconds == null ? this.writerCpuSeconds : writerCpuSeconds(),
      otherCpuSeconds: otherCpuSeconds == null ? this.otherCpuSeconds : otherCpuSeconds(),
      writers: writers ?? this.writers,
      writersBusy: writersBusy ?? this.writersBusy,
      queueWaitMeanMs: queueWaitMeanMs ?? this.queueWaitMeanMs,
      queueWaitTotalSeconds: queueWaitTotalSeconds ?? this.queueWaitTotalSeconds,
      stages: stages ?? this.stages,
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
    TraitHelpers.serializeOptionF64(writerCpuSeconds, serializer);
    TraitHelpers.serializeOptionF64(otherCpuSeconds, serializer);
    serializer.serializeUint32(writers);
    serializer.serializeFloat64(writersBusy);
    serializer.serializeFloat64(queueWaitMeanMs);
    serializer.serializeFloat64(queueWaitTotalSeconds);
    TraitHelpers.serializeVectorStageTiming(stages, serializer);
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
      && cpuMsPerMib == other.cpuMsPerMib
      && writerCpuSeconds == other.writerCpuSeconds
      && otherCpuSeconds == other.otherCpuSeconds
      && writers == other.writers
      && writersBusy == other.writersBusy
      && queueWaitMeanMs == other.queueWaitMeanMs
      && queueWaitTotalSeconds == other.queueWaitTotalSeconds
      && listEquals(stages, other.stages);
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
        writerCpuSeconds,
        otherCpuSeconds,
        writers,
        writersBusy,
        queueWaitMeanMs,
        queueWaitTotalSeconds,
        stages,
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
        'cpuMsPerMib: $cpuMsPerMib, '
        'writerCpuSeconds: $writerCpuSeconds, '
        'otherCpuSeconds: $otherCpuSeconds, '
        'writers: $writers, '
        'writersBusy: $writersBusy, '
        'queueWaitMeanMs: $queueWaitMeanMs, '
        'queueWaitTotalSeconds: $queueWaitTotalSeconds, '
        'stages: $stages'
        ')';
      return true;
    }());

    return fullString ?? 'TransferDone';
  }
}

final _transferDoneStreamController =
    StreamController<RustSignalPack<TransferDone>>();
