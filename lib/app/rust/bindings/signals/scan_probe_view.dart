// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The scan probe: the text report, and its figures.
@immutable
class ScanProbeView {
  const ScanProbeView({
    required this.root,
    required this.report,
    required this.passes,
  });

  static ScanProbeView deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ScanProbeView(
      root: deserializer.deserializeString(),
      report: deserializer.deserializeString(),
      passes: TraitHelpers.deserializeVectorScanPassView(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ScanProbeView bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ScanProbeView.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String root;
  final String report;
  final List<ScanPassView> passes;

  ScanProbeView copyWith({
    String? root,
    String? report,
    List<ScanPassView>? passes,
  }) {
    return ScanProbeView(
      root: root ?? this.root,
      report: report ?? this.report,
      passes: passes ?? this.passes,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(root);
    serializer.serializeString(report);
    TraitHelpers.serializeVectorScanPassView(passes, serializer);
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

    return other is ScanProbeView
      && root == other.root
      && report == other.report
      && listEquals(passes, other.passes);
  }

  @override
  int get hashCode => Object.hash(
        root,
        report,
        passes,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'root: $root, '
        'report: $report, '
        'passes: $passes'
        ')';
      return true;
    }());

    return fullString ?? 'ScanProbeView';
  }
}
