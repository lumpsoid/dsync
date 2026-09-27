// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A run view's plan, as an update to the one the head holds.
abstract class PlanUpdateView {
  const PlanUpdateView();

  void serialize(BinarySerializer serializer);

  static PlanUpdateView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return PlanUpdateViewAbsent.load(deserializer);
      case 1: return PlanUpdateViewNew.load(deserializer);
      case 2: return PlanUpdateViewSame.load(deserializer);
      default: throw Exception('Unknown variant index for PlanUpdateView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static PlanUpdateView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = PlanUpdateView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class PlanUpdateViewAbsent extends PlanUpdateView {
  const PlanUpdateViewAbsent(
  ) : super();

  static PlanUpdateViewAbsent load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PlanUpdateViewAbsent(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(0);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PlanUpdateViewAbsent;
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        ')';
      return true;
    }());

    return fullString ?? 'PlanUpdateViewAbsent';
  }
}

@immutable
class PlanUpdateViewNew extends PlanUpdateView {
  const PlanUpdateViewNew({
    required this.value,
  }) : super();

  static PlanUpdateViewNew load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PlanUpdateViewNew(
      value: PlanView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final PlanView value;

  PlanUpdateViewNew copyWith({
    PlanView? value,
  }) {
    return PlanUpdateViewNew(
      value: value ?? this.value,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    value.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PlanUpdateViewNew
      && value == other.value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'value: $value'
        ')';
      return true;
    }());

    return fullString ?? 'PlanUpdateViewNew';
  }
}

@immutable
class PlanUpdateViewSame extends PlanUpdateView {
  const PlanUpdateViewSame({
    required this.actions,
    required this.conflicts,
  }) : super();

  static PlanUpdateViewSame load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = PlanUpdateViewSame(
      actions: TraitHelpers.deserializeVectorActionRowUpdateView(deserializer),
      conflicts: TraitHelpers.deserializeVectorConflictRowUpdateView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final List<ActionRowUpdateView> actions;
  final List<ConflictRowUpdateView> conflicts;

  PlanUpdateViewSame copyWith({
    List<ActionRowUpdateView>? actions,
    List<ConflictRowUpdateView>? conflicts,
  }) {
    return PlanUpdateViewSame(
      actions: actions ?? this.actions,
      conflicts: conflicts ?? this.conflicts,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    TraitHelpers.serializeVectorActionRowUpdateView(actions, serializer);
    TraitHelpers.serializeVectorConflictRowUpdateView(conflicts, serializer);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is PlanUpdateViewSame
      && listEquals(actions, other.actions)
      && listEquals(conflicts, other.conflicts);
  }

  @override
  int get hashCode => Object.hash(
        actions,
        conflicts,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'actions: $actions, '
        'conflicts: $conflicts'
        ')';
      return true;
    }());

    return fullString ?? 'PlanUpdateViewSame';
  }
}
