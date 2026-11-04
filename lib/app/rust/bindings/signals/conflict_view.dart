// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A conflict (SPEC §6), each side's status as the scan found it.
@immutable
class ConflictView {
  const ConflictView({
    required this.path,
    this.a,
    this.b,
    required this.cause,
  });

  static ConflictView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ConflictView(
      path: deserializer.deserializeString(),
      a: TraitHelpers.deserializeOptionStatusView(deserializer),
      b: TraitHelpers.deserializeOptionStatusView(deserializer),
      cause: ConflictCauseView.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ConflictView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ConflictView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String path;
  final StatusView? a;
  final StatusView? b;
  final ConflictCauseView cause;

  ConflictView copyWith({
    String? path,
    StatusView? Function()? a,
    StatusView? Function()? b,
    ConflictCauseView? cause,
  }) {
    return ConflictView(
      path: path ?? this.path,
      a: a == null ? this.a : a(),
      b: b == null ? this.b : b(),
      cause: cause ?? this.cause,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(path);
    TraitHelpers.serializeOptionStatusView(a, serializer);
    TraitHelpers.serializeOptionStatusView(b, serializer);
    cause.serialize(serializer);
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

    return other is ConflictView
      && path == other.path
      && a == other.a
      && b == other.b
      && cause == other.cause;
  }

  @override
  int get hashCode => Object.hash(
        path,
        a,
        b,
        cause,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'a: $a, '
        'b: $b, '
        'cause: $cause'
        ')';
      return true;
    }());

    return fullString ?? 'ConflictView';
  }
}
