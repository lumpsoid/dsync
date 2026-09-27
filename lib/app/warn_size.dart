import 'format_bytes.dart';

/// The head's default large-transfer warning (SPEC §10): off, or a size a
/// run's plan is warned about moving more than. The head's equivalent of
/// the CLI's `--warn-size`, but beneath a profile's own
/// `options.warn_size_bytes` rather than over it.
///
/// A sealed value rather than an `int?` so "off" is a case of its own and
/// the size is checked once, where the value is made — at the Settings
/// page's field and at the settings store's parse.
sealed class WarnSize {
  const WarnSize();

  /// A size as the user typed it: a number with an optional unit — `B`,
  /// decimal `KB`/`MB`/`GB`/`TB` (×1000) or binary `KiB`/`MiB`/`GiB`/`TiB`
  /// (×1024), any case, a space before it or not — rounded to whole
  /// bytes. A bare number is bytes and must be whole; a unit allows a
  /// fraction (`1.5 GB`). Nothing at all is off. Throws [FormatException]
  /// saying what to type instead, for zero or less too.
  factory WarnSize.parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const WarnSizeOff();
    final refused = FormatException(
      '"$text" is not a size. Give one above 0, e.g. 500 MB or 2 GiB, or '
      'leave it empty to turn the warning off.',
    );
    final match = _typed.firstMatch(trimmed);
    if (match == null) throw refused;
    final number = match.group(1)!;
    final unit = match.group(2)!.toLowerCase();
    final multiplier = _units[unit];
    if (multiplier == null) throw refused;
    // A bare number is bytes, and a byte does not split.
    if (unit.isEmpty && number.contains('.')) throw refused;
    final exact = double.parse(number) * multiplier;
    // Past 2^53 a double no longer holds every whole byte, and nobody
    // warns above 9 PB.
    if (exact > 9007199254740992) throw refused;
    final bytes = exact.round();
    if (bytes < 1) throw refused;
    return WarnSizeAbove._(bytes);
  }

  static final _typed = RegExp(r'^(\d+(?:\.\d+)?)\s*([a-zA-Z]*)$');

  static const _units = {
    '': 1,
    'b': 1,
    'kb': 1000,
    'mb': 1000 * 1000,
    'gb': 1000 * 1000 * 1000,
    'tb': 1000 * 1000 * 1000 * 1000,
    'kib': 1024,
    'mib': 1024 * 1024,
    'gib': 1024 * 1024 * 1024,
    'tib': 1024 * 1024 * 1024 * 1024,
  };
}

/// No warning: what an installation that never set one runs with.
final class WarnSizeOff extends WarnSize {
  const WarnSizeOff();

  @override
  bool operator ==(Object other) => other is WarnSizeOff;

  @override
  int get hashCode => 0;
}

/// Warn when a plan moves more than [bytes].
final class WarnSizeAbove extends WarnSize {
  const WarnSizeAbove._(this.bytes);

  /// [bytes] as a size. Throws [FormatException] below 1.
  factory WarnSizeAbove(int bytes) {
    if (bytes < 1) {
      throw FormatException('$bytes is not a size; give one above 0 bytes.');
    }
    return WarnSizeAbove._(bytes);
  }

  final int bytes;

  /// [bytes] as the user could have typed it, exactly: in the largest unit
  /// it is a whole number of (`500 MB`, `2 GiB`), else in bytes. What the
  /// Settings dialog opens with, so saving it unchanged keeps the size.
  String get typed {
    for (final (unit, size) in _largestFirst) {
      if (bytes % size == 0) return '${bytes ~/ size} $unit';
    }
    return '$bytes B';
  }

  /// [bytes] as the Settings page shows it: [typed] when that is a whole
  /// number of some unit, so `500 MB` reads as it was typed rather than as
  /// `477 MiB`; the page's usual [formatBytes] otherwise.
  String get label {
    final exact = typed;
    return exact.endsWith(' B') ? formatBytes(bytes) : exact;
  }

  static const _largestFirst = [
    ('TiB', 1024 * 1024 * 1024 * 1024),
    ('TB', 1000 * 1000 * 1000 * 1000),
    ('GiB', 1024 * 1024 * 1024),
    ('GB', 1000 * 1000 * 1000),
    ('MiB', 1024 * 1024),
    ('MB', 1000 * 1000),
    ('KiB', 1024),
    ('KB', 1000),
  ];

  @override
  bool operator ==(Object other) =>
      other is WarnSizeAbove && other.bytes == bytes;

  @override
  int get hashCode => bytes.hashCode;
}
