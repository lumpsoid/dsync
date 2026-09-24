// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class AddressesView {
  const AddressesView({
    required this.interfaces,
    this.preferred,
  });

  static AddressesView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = AddressesView(
      interfaces: TraitHelpers.deserializeVectorStr(deserializer),
      preferred: TraitHelpers.deserializeOptionStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static AddressesView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = AddressesView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final List<String> interfaces;
  final String? preferred;

  AddressesView copyWith({
    List<String>? interfaces,
    String? Function()? preferred,
  }) {
    return AddressesView(
      interfaces: interfaces ?? this.interfaces,
      preferred: preferred == null ? this.preferred : preferred(),
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    TraitHelpers.serializeVectorStr(interfaces, serializer);
    TraitHelpers.serializeOptionStr(preferred, serializer);
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

    return other is AddressesView
      && listEquals(interfaces, other.interfaces)
      && preferred == other.preferred;
  }

  @override
  int get hashCode => Object.hash(
        interfaces,
        preferred,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'interfaces: $interfaces, '
        'preferred: $preferred'
        ')';
      return true;
    }());

    return fullString ?? 'AddressesView';
  }
}
