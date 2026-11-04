// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// [`LastRun`], for the head.
enum LastRunView {
  settled,
  writeHeld,
  died,
}

extension LastRunViewExtension on LastRunView {
  static LastRunView deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return LastRunView.settled;
      case 1: return LastRunView.writeHeld;
      case 2: return LastRunView.died;
      default: throw Exception('Unknown variant index for LastRunView: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case LastRunView.settled: return serializer.serializeVariantIndex(0);
      case LastRunView.writeHeld: return serializer.serializeVariantIndex(1);
      case LastRunView.died: return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static LastRunView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = LastRunViewExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

