/// Bytes as a page shows them; `intl` is not a dependency and this is the
/// only formatting the head needs.
///
/// Top-level in `lib/app/` rather than inside a feature: the Run page renders
/// what a plan will transfer with it and the Archives page renders what a
/// log costs with it, and one of those reaching into the other's controller
/// for a pure formatter would couple two features over nothing.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}
