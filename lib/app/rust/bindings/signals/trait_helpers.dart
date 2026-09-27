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

  static void serializeOptionReplicasView(ReplicasView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static ReplicasView? deserializeOptionReplicasView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return ReplicasView.deserialize(deserializer);
    } else {
        return null;
    }
  }

  static void serializeOptionResultView(ResultView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static ResultView? deserializeOptionResultView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return ResultView.deserialize(deserializer);
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

  static void serializeOptionTalliesView(TalliesView? value, BinarySerializer serializer) {
    if (value == null) {
        serializer.serializeOptionTag(false);
    } else {
        serializer.serializeOptionTag(true);
        value.serialize(serializer);
    }
  }

  static TalliesView? deserializeOptionTalliesView(BinaryDeserializer deserializer) {
    final tag = deserializer.deserializeOptionTag();
    if (tag) {
        return TalliesView.deserialize(deserializer);
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

  static void serializeVectorActionRowUpdateView(List<ActionRowUpdateView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ActionRowUpdateView> deserializeVectorActionRowUpdateView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ActionRowUpdateView.deserialize(deserializer));
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

  static void serializeVectorConflictChoiceView(List<ConflictChoiceView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ConflictChoiceView> deserializeVectorConflictChoiceView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ConflictChoiceViewExtension.deserialize(deserializer));
  }

  static void serializeVectorConflictRowUpdateView(List<ConflictRowUpdateView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ConflictRowUpdateView> deserializeVectorConflictRowUpdateView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ConflictRowUpdateView.deserialize(deserializer));
  }

  static void serializeVectorConflictRowView(List<ConflictRowView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ConflictRowView> deserializeVectorConflictRowView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ConflictRowView.deserialize(deserializer));
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

  static void serializeVectorEntryDraft(List<EntryDraft> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<EntryDraft> deserializeVectorEntryDraft(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => EntryDraft.deserialize(deserializer));
  }

  static void serializeVectorEntryIssueView(List<EntryIssueView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<EntryIssueView> deserializeVectorEntryIssueView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => EntryIssueView.deserialize(deserializer));
  }

  static void serializeVectorEntryRunView(List<EntryRunView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<EntryRunView> deserializeVectorEntryRunView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => EntryRunView.deserialize(deserializer));
  }

  static void serializeVectorEntryView(List<EntryView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<EntryView> deserializeVectorEntryView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => EntryView.deserialize(deserializer));
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

  static void serializeVectorMassDeleteView(List<MassDeleteView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<MassDeleteView> deserializeVectorMassDeleteView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => MassDeleteView.deserialize(deserializer));
  }

  static void serializeVectorOtherEntryView(List<OtherEntryView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<OtherEntryView> deserializeVectorOtherEntryView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => OtherEntryView.deserialize(deserializer));
  }

  static void serializeVectorPlanRowView(List<PlanRowView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<PlanRowView> deserializeVectorPlanRowView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => PlanRowView.deserialize(deserializer));
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

  static void serializeVectorServeLineView(List<ServeLineView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ServeLineView> deserializeVectorServeLineView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ServeLineView.deserialize(deserializer));
  }

  static void serializeVectorSkippedView(List<SkippedView> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<SkippedView> deserializeVectorSkippedView(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => SkippedView.deserialize(deserializer));
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

