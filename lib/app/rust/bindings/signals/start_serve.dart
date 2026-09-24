// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Dart asks Rust to receive one tree into [root] on [port], from the peer
/// whose device id is [allow_peer_id] (or `ANY`), with [writers] blocking
/// file-writer threads (at least one).
@immutable
class StartServe {
  const StartServe({
    required this.root,
    required this.port,
    required this.allowPeerId,
    required this.writers,
  });

  static StartServe deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = StartServe(
      root: deserializer.deserializeString(),
      port: deserializer.deserializeUint16(),
      allowPeerId: deserializer.deserializeString(),
      writers: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static StartServe bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = StartServe.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String root;
  final int port;
  final String allowPeerId;
  final int writers;

  StartServe copyWith({
    String? root,
    int? port,
    String? allowPeerId,
    int? writers,
  }) {
    return StartServe(
      root: root ?? this.root,
      port: port ?? this.port,
      allowPeerId: allowPeerId ?? this.allowPeerId,
      writers: writers ?? this.writers,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(root);
    serializer.serializeUint16(port);
    serializer.serializeString(allowPeerId);
    serializer.serializeUint32(writers);
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

    return other is StartServe
      && root == other.root
      && port == other.port
      && allowPeerId == other.allowPeerId
      && writers == other.writers;
  }

  @override
  int get hashCode => Object.hash(
        root,
        port,
        allowPeerId,
        writers,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'root: $root, '
        'port: $port, '
        'allowPeerId: $allowPeerId, '
        'writers: $writers'
        ')';
      return true;
    }());

    return fullString ?? 'StartServe';
  }
}

extension StartServeDartSignalExt on StartServe {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_start_serve',
      messageBytes,
      binary,
    );
  }
}
