// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A planned action under review: as planned, reversed (the loser's
/// version put back, only where the proposal offers it), or left out.
enum ActionChoiceView {
  proposed,
  reversed,
  skipped,
}

extension ActionChoiceViewExtension on ActionChoiceView {
  static ActionChoiceView deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return ActionChoiceView.proposed;
      case 1: return ActionChoiceView.reversed;
      case 2: return ActionChoiceView.skipped;
      default: throw Exception('Unknown variant index for ActionChoiceView: ' + index.toString());
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case ActionChoiceView.proposed: return serializer.serializeVariantIndex(0);
      case ActionChoiceView.reversed: return serializer.serializeVariantIndex(1);
      case ActionChoiceView.skipped: return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static ActionChoiceView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ActionChoiceViewExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}

