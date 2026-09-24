/// One rung of one pass.
final class ScanProbeLayer {
  const ScanProbeLayer({
    required this.label,
    required this.elapsed,
    required this.files,
    required this.directories,
    required this.bytes,
    required this.microsPerFile,
  });

  final String label;
  final Duration elapsed;
  final int files;
  final int? directories;
  final int bytes;
  final double microsPerFile;
}
