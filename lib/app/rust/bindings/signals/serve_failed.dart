// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Serving ended without a finished transfer: bind, handshake, I/O, or a
/// refused peer. A [StopServe] ends it without this. When a writer failed,
/// the last four say on which file, at which stage, and the io error's kind
/// and OS code.
@immutable
class ServeFailed {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _serveFailedStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<ServeFailed>? latestRustSignal = null;

  const ServeFailed({
    required this.message,
    this.path,
    this.stage,
    this.ioKind,
    this.osCode,
  });

  static ServeFailed deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ServeFailed(
      message: deserializer.deserializeString(),
      path: TraitHelpers.deserializeOptionStr(deserializer),
      stage: TraitHelpers.deserializeOptionStr(deserializer),
      ioKind: TraitHelpers.deserializeOptionStr(deserializer),
      osCode: TraitHelpers.deserializeOptionI32(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ServeFailed bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ServeFailed.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String message;
  final String? path;
  final String? stage;
  final String? ioKind;
  final int? osCode;

  ServeFailed copyWith({
    String? message,
    String? Function()? path,
    String? Function()? stage,
    String? Function()? ioKind,
    int? Function()? osCode,
  }) {
    return ServeFailed(
      message: message ?? this.message,
      path: path == null ? this.path : path(),
      stage: stage == null ? this.stage : stage(),
      ioKind: ioKind == null ? this.ioKind : ioKind(),
      osCode: osCode == null ? this.osCode : osCode(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(message);
    TraitHelpers.serializeOptionStr(path, serializer);
    TraitHelpers.serializeOptionStr(stage, serializer);
    TraitHelpers.serializeOptionStr(ioKind, serializer);
    TraitHelpers.serializeOptionI32(osCode, serializer);
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

    return other is ServeFailed
      && message == other.message
      && path == other.path
      && stage == other.stage
      && ioKind == other.ioKind
      && osCode == other.osCode;
  }

  @override
  int get hashCode => Object.hash(
        message,
        path,
        stage,
        ioKind,
        osCode,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'message: $message, '
        'path: $path, '
        'stage: $stage, '
        'ioKind: $ioKind, '
        'osCode: $osCode'
        ')';
      return true;
    }());

    return fullString ?? 'ServeFailed';
  }
}

final _serveFailedStreamController =
    StreamController<RustSignalPack<ServeFailed>>();
