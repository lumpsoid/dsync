// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A path a scan skipped. `is_failure` is the reason's own verdict
/// (SPEC §5.1): a symlink is the rules obeyed, the rest a side unable to
/// stand behind a status.
@immutable
class SkippedView {
  const SkippedView({
    required this.side,
    required this.path,
    required this.reason,
    required this.detail,
    required this.isFailure,
  });

  static SkippedView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SkippedView(
      side: SideViewExtension.deserialize(deserializer),
      path: deserializer.deserializeString(),
      reason: SkippedReasonViewExtension.deserialize(deserializer),
      detail: deserializer.deserializeString(),
      isFailure: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SkippedView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SkippedView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final SideView side;
  final String path;
  final SkippedReasonView reason;
  final String detail;
  final bool isFailure;

  SkippedView copyWith({
    SideView? side,
    String? path,
    SkippedReasonView? reason,
    String? detail,
    bool? isFailure,
  }) {
    return SkippedView(
      side: side ?? this.side,
      path: path ?? this.path,
      reason: reason ?? this.reason,
      detail: detail ?? this.detail,
      isFailure: isFailure ?? this.isFailure,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    side.serialize(serializer);
    serializer.serializeString(path);
    reason.serialize(serializer);
    serializer.serializeString(detail);
    serializer.serializeBool(isFailure);
    serializer.decreaseContainerDepth();
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is SkippedView
      && side == other.side
      && path == other.path
      && reason == other.reason
      && detail == other.detail
      && isFailure == other.isFailure;
  }

  @override
  int get hashCode => Object.hash(
        side,
        path,
        reason,
        detail,
        isFailure,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'side: $side, '
        'path: $path, '
        'reason: $reason, '
        'detail: $detail, '
        'isFailure: $isFailure'
        ')';
      return true;
    }());

    return fullString ?? 'SkippedView';
  }
}
