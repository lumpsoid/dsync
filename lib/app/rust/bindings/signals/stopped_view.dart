// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


enum StoppedView {
  gracefully,
  dropped,
}

extension StoppedViewExtension on StoppedView {
  static StoppedView deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return StoppedView.gracefully;
      case 1: return StoppedView.dropped;
      default: throw Exception('Unknown variant index for StoppedView: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case StoppedView.gracefully: return serializer.serializeVariantIndex(0);
      case StoppedView.dropped: return serializer.serializeVariantIndex(1);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static StoppedView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = StoppedViewExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

