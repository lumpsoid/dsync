// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


abstract class EntryStatusView {
  const EntryStatusView();

  void serialize(BinarySerializer serializer);

  static EntryStatusView deserialize(BinaryDeserializer deserializer) {
    int index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0: return EntryStatusViewPending.load(deserializer);
      case 1: return EntryStatusViewRunning.load(deserializer);
      case 2: return EntryStatusViewSynced.load(deserializer);
      case 3: return EntryStatusViewSkipped.load(deserializer);
      case 4: return EntryStatusViewFailed.load(deserializer);
      case 5: return EntryStatusViewNotRun.load(deserializer);
      default: throw Exception('Unknown variant index for EntryStatusView: ' + index.toString());
    }
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  static EntryStatusView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = EntryStatusView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}


@immutable
class EntryStatusViewPending extends EntryStatusView {
  const EntryStatusViewPending(
  ) : super();

  static EntryStatusViewPending load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryStatusViewPending(
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

    return other is EntryStatusViewPending;
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

    return fullString ?? 'EntryStatusViewPending';
  }
}

@immutable
class EntryStatusViewRunning extends EntryStatusView {
  const EntryStatusViewRunning(
  ) : super();

  static EntryStatusViewRunning load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryStatusViewRunning(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(1);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EntryStatusViewRunning;
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

    return fullString ?? 'EntryStatusViewRunning';
  }
}

@immutable
class EntryStatusViewSynced extends EntryStatusView {
  const EntryStatusViewSynced(
  ) : super();

  static EntryStatusViewSynced load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryStatusViewSynced(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(2);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EntryStatusViewSynced;
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

    return fullString ?? 'EntryStatusViewSynced';
  }
}

@immutable
class EntryStatusViewSkipped extends EntryStatusView {
  const EntryStatusViewSkipped({
    required this.reason,
  }) : super();

  static EntryStatusViewSkipped load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryStatusViewSkipped(
      reason: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String reason;

  EntryStatusViewSkipped copyWith({
    String? reason,
  }) {
    return EntryStatusViewSkipped(
      reason: reason ?? this.reason,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(3);
    serializer.serializeString(reason);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EntryStatusViewSkipped
      && reason == other.reason;
  }

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'reason: $reason'
        ')';
      return true;
    }());

    return fullString ?? 'EntryStatusViewSkipped';
  }
}

@immutable
class EntryStatusViewFailed extends EntryStatusView {
  const EntryStatusViewFailed({
    required this.message,
  }) : super();

  static EntryStatusViewFailed load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryStatusViewFailed(
      message: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  final String message;

  EntryStatusViewFailed copyWith({
    String? message,
  }) {
    return EntryStatusViewFailed(
      message: message ?? this.message,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(4);
    serializer.serializeString(message);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EntryStatusViewFailed
      && message == other.message;
  }

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'message: $message'
        ')';
      return true;
    }());

    return fullString ?? 'EntryStatusViewFailed';
  }
}

@immutable
class EntryStatusViewNotRun extends EntryStatusView {
  const EntryStatusViewNotRun(
  ) : super();

  static EntryStatusViewNotRun load(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = EntryStatusViewNotRun(
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeVariantIndex(5);
    serializer.decreaseContainerDepth();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is EntryStatusViewNotRun;
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

    return fullString ?? 'EntryStatusViewNotRun';
  }
}
