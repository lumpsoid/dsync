// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


enum SkippedReasonView {
  symlink,
  unreadable,
  caseFoldCollision,
  unrepresentableName,
}

extension SkippedReasonViewExtension on SkippedReasonView {
  static SkippedReasonView deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return SkippedReasonView.symlink;
      case 1: return SkippedReasonView.unreadable;
      case 2: return SkippedReasonView.caseFoldCollision;
      case 3: return SkippedReasonView.unrepresentableName;
      default: throw Exception('Unknown variant index for SkippedReasonView: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case SkippedReasonView.symlink: return serializer.serializeVariantIndex(0);
      case SkippedReasonView.unreadable: return serializer.serializeVariantIndex(1);
      case SkippedReasonView.caseFoldCollision: return serializer.serializeVariantIndex(2);
      case SkippedReasonView.unrepresentableName: return serializer.serializeVariantIndex(3);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static SkippedReasonView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SkippedReasonViewExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

