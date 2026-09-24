import 'scan_probe_layer.dart';

/// What scanning a folder costs, layer by layer, pass by pass: the text
/// [report] and its figures.
final class ScanProbeResult {
  const ScanProbeResult({
    required this.root,
    required this.report,
    required this.passes,
  });

  final String root;
  final String report;

  /// Per pass, its layers in order.
  final List<List<ScanProbeLayer>> passes;
}
