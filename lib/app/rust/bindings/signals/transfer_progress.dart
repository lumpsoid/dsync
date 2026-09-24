// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Files and bytes on disk so far; at most one per 50 ms.
@immutable
class TransferProgress {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _transferProgressStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<TransferProgress>? latestRustSignal = null;

  const TransferProgress({
    required this.files,
    required this.bytes,
  });

  static TransferProgress deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = TransferProgress(
      files: deserializer.deserializeUint64(),
      bytes: deserializer.deserializeUint64(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static TransferProgress bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = TransferProgress.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final Uint64 files;
  final Uint64 bytes;

  TransferProgress copyWith({
    Uint64? files,
    Uint64? bytes,
  }) {
    return TransferProgress(
      files: files ?? this.files,
      bytes: bytes ?? this.bytes,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint64(files);
    serializer.serializeUint64(bytes);
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

    return other is TransferProgress
      && files == other.files
      && bytes == other.bytes;
  }

  @override
  int get hashCode => Object.hash(
        files,
        bytes,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'files: $files, '
        'bytes: $bytes'
        ')';
      return true;
    }());

    return fullString ?? 'TransferProgress';
  }
}

final _transferProgressStreamController =
    StreamController<RustSignalPack<TransferProgress>>();
