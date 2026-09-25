// ignore_for_file: type=lint, type=warning
part of 'signals.dart';
class TraitHelpers {
  static void serializeOptionMissingRootView(MissingRootView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static MissingRootView? deserializeOptionMissingRootView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return MissingRootView.deserialize(deserializer);
    } else {
        return null;
    }
  }

  static void serializeOptionProgressView(ProgressView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static ProgressView? deserializeOptionProgressView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return ProgressView.deserialize(deserializer);
    } else {
        return null;
    }
  }

  static void serializeOptionSideView(SideView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static SideView? deserializeOptionSideView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return SideViewExtension.deserialize(deserializer);
    } else {
        return null;
    }
  }

  static void serializeOptionStatusView(StatusView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static StatusView? deserializeOptionStatusView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return StatusView.deserialize(deserializer);
    } else {
        return null;
    }
  }

  static void serializeOptionStoppedView(StoppedView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static StoppedView? deserializeOptionStoppedView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return StoppedViewExtension.deserialize(deserializer);
    } else {
        return null;
    }
  }

  static void serializeOptionSummaryView(SummaryView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static SummaryView? deserializeOptionSummaryView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return SummaryView.deserialize(deserializer);
    } else {
        return null;
    }
  }

  static void serializeOptionI64(int? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        serializer.serializeInt64(value);
    }
  }

  static int? deserializeOptionI64(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return deserializer.deserializeInt64();
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

  static void serializeOptionU32(int? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        serializer.serializeUint32(value);
    }
  }

  static int? deserializeOptionU32(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return deserializer.deserializeUint32();
    } else {
        return null;
    }
  }

  static void serializeOptionU64(Uint64? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        serializer.serializeUint64(value);
    }
  }

  static Uint64? deserializeOptionU64(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return deserializer.deserializeUint64();
    } else {
        return null;
    }
  }

  static void serializeVectorActionView(List<ActionView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ActionView> deserializeVectorActionView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ActionView.deserialize(deserializer));
  }

  static void serializeVectorArchiveView(List<ArchiveView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ArchiveView> deserializeVectorArchiveView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ArchiveView.deserialize(deserializer));
  }

  static void serializeVectorConflictChoice(List<ConflictChoice> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ConflictChoice> deserializeVectorConflictChoice(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ConflictChoice.deserialize(deserializer));
  }

  static void serializeVectorConflictView(List<ConflictView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ConflictView> deserializeVectorConflictView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ConflictView.deserialize(deserializer));
  }

  static void serializeVectorDeviceView(List<DeviceView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<DeviceView> deserializeVectorDeviceView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => DeviceView.deserialize(deserializer));
  }

  static void serializeVectorFilterFolderView(List<FilterFolderView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<FilterFolderView> deserializeVectorFilterFolderView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => FilterFolderView.deserialize(deserializer));
  }

  static void serializeVectorFilterRowView(List<FilterRowView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<FilterRowView> deserializeVectorFilterRowView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => FilterRowView.deserialize(deserializer));
  }

  static void serializeVectorKeptAction(List<KeptAction> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<KeptAction> deserializeVectorKeptAction(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => KeptAction.deserialize(deserializer));
  }

  static void serializeVectorPeerContactView(List<PeerContactView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<PeerContactView> deserializeVectorPeerContactView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => PeerContactView.deserialize(deserializer));
  }

  static void serializeVectorProfileEntry(List<ProfileEntry> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ProfileEntry> deserializeVectorProfileEntry(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ProfileEntry.deserialize(deserializer));
  }

  static void serializeVectorProposalView(List<ProposalView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ProposalView> deserializeVectorProposalView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ProposalView.deserialize(deserializer));
  }

  static void serializeVectorResultView(List<ResultView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ResultView> deserializeVectorResultView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ResultView.deserialize(deserializer));
  }

  static void serializeVectorRuleCountView(List<RuleCountView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<RuleCountView> deserializeVectorRuleCountView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => RuleCountView.deserialize(deserializer));
  }

  static void serializeVectorScanLayerView(List<ScanLayerView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ScanLayerView> deserializeVectorScanLayerView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ScanLayerView.deserialize(deserializer));
  }

  static void serializeVectorScanPassView(List<ScanPassView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ScanPassView> deserializeVectorScanPassView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ScanPassView.deserialize(deserializer));
  }

  static void serializeVectorStr(List<String> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        serializer.serializeString(item);
    }
  }

  static List<String> deserializeVectorStr(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => deserializer.deserializeString());
  }

}

