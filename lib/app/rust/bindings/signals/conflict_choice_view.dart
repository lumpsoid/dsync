// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A conflict under review: left open, settled toward one side, or both
/// versions kept - side B's saved beside side A's.
enum ConflictChoiceView {
  unresolved,
  keepA,
  keepB,
  keepBoth,
}

extension ConflictChoiceViewExtension on ConflictChoiceView {
  static ConflictChoiceView deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ConflictChoiceView.unresolved;
      case 1: return ConflictChoiceView.keepA;
      case 2: return ConflictChoiceView.keepB;
      case 3: return ConflictChoiceView.keepBoth;
      default: throw Exception('Unknown variant index for ConflictChoiceView: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case ConflictChoiceView.unresolved: return serializer.serializeVariantIndex(0);
      case ConflictChoiceView.keepA: return serializer.serializeVariantIndex(1);
      case ConflictChoiceView.keepB: return serializer.serializeVariantIndex(2);
      case ConflictChoiceView.keepBoth: return serializer.serializeVariantIndex(3);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ConflictChoiceView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ConflictChoiceViewExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

