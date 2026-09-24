// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ScanPassView {
  const ScanPassView({
    required this.index,
    required this.layers,
  });

  static ScanPassView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ScanPassView(
      index: deserializer.deserializeUint32(),
      layers: TraitHelpers.deserializeVectorScanLayerView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ScanPassView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ScanPassView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int index;
  final List<ScanLayerView> layers;

  ScanPassView copyWith({
    int? index,
    List<ScanLayerView>? layers,
  }) {
    return ScanPassView(
      index: index ?? this.index,
      layers: layers ?? this.layers,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(index);
    TraitHelpers.serializeVectorScanLayerView(layers, serializer);
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

    return other is ScanPassView
      && index == other.index
      && listEquals(layers, other.layers);
  }

  @override
  int get hashCode => Object.hash(
        index,
        layers,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'index: $index, '
        'layers: $layers'
        ')';
      return true;
    }());

    return fullString ?? 'ScanPassView';
  }
}
