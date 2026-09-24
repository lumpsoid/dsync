// ignore_for_file: type=lint, type=warning
part of 'signals.dart';
class TraitHelpers {
  static void serializeOptionF64(double? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        serializer.serializeFloat64(value);
    }
  }

  static double? deserializeOptionF64(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return deserializer.deserializeFloat64();
    } else {
        return null;
    }
  }

}

