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

  static void serializeOptionI32(int? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        serializer.serializeInt32(value);
    }
  }

  static int? deserializeOptionI32(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return deserializer.deserializeInt32();
    } else {
        return null;
    }
  }

  static void serializeOptionStr(String? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        serializer.serializeString(value);
    }
  }

  static String? deserializeOptionStr(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return deserializer.deserializeString();
    } else {
        return null;
    }
  }

  static void serializeVectorStageTiming(List<StageTiming> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<StageTiming> deserializeVectorStageTiming(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => StageTiming.deserialize(deserializer));
  }

}

