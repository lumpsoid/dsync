// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


enum SideView {
  a,
  b,
}

extension SideViewExtension on SideView {
  static SideView deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return SideView.a;
      case 1: return SideView.b;
      default: throw Exception('Unknown variant index for SideView: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case SideView.a: return serializer.serializeVariantIndex(0);
      case SideView.b: return serializer.serializeVariantIndex(1);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static SideView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SideViewExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

