// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Dart asks Rust to stop serving, mid-transfer or before one starts.
@immutable
class StopServe {
  const StopServe(
  );

  static StopServe deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = StopServe(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static StopServe bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = StopServe.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
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

    return other is StopServe;
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

    return fullString ?? 'StopServe';
  }
}

extension StopServeDartSignalExt on StopServe {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_stop_serve',
      messageBytes,
      binary,
    );
  }
}
