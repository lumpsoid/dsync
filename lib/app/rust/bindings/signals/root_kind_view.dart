// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What an entry's two roots are: folders, or one file each.
enum RootKindView {
  folder,
  file,
}

extension RootKindViewExtension on RootKindView {
  static RootKindView deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return RootKindView.folder;
      case 1: return RootKindView.file;
      default: throw Exception('Unknown variant index for RootKindView: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case RootKindView.folder: return serializer.serializeVariantIndex(0);
      case RootKindView.file: return serializer.serializeVariantIndex(1);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static RootKindView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = RootKindViewExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

