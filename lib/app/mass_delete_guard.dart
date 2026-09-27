/// When a sync stops to ask before it deletes (SPEC §10's guard): once it
/// would delete at least [minFiles] files on one side *and* more than
/// [percent] of the files that side last synced.
///
/// Thresholds, never a switch: there is no value that turns the guard off.
/// Past it, the run's own confirmation is the only way through.
///
/// The ranges are the core's `MassDeletePolicy::new`, checked here, where
/// the value is made — at the Settings page's field and at the settings
/// store's parse — so a run never sends a pair the core refuses:
/// [minFiles] at least 1, [percent] from 1 to 100.
final class MassDeleteGuard {
  const MassDeleteGuard._(this.minFiles, this.percent);

  /// The two thresholds. Throws [FormatException] when either is out of
  /// range.
  factory MassDeleteGuard({required int minFiles, required int percent}) {
    if (!_isMinFiles(minFiles)) {
      throw FormatException(
        '$minFiles is not a file count; give a whole number of at least 1.',
      );
    }
    if (!_isPercent(percent)) {
      throw FormatException(
        '$percent is not a percent; give a whole number from 1 to 100.',
      );
    }
    return MassDeleteGuard._(minFiles, percent);
  }

  /// The core's default, and the CLI's: ten files, and over half of the
  /// side.
  static const defaults = MassDeleteGuard._(10, 50);

  final int minFiles;
  final int percent;

  /// A file count as the user typed it: a whole number of at least 1.
  /// Throws [FormatException] saying what to type instead.
  static int parseMinFiles(String text) {
    final value = int.tryParse(text.trim());
    if (value == null || !_isMinFiles(value)) {
      throw FormatException(
        '"$text" is not a file count. Give a whole number of at least 1.',
      );
    }
    return value;
  }

  /// A percent as the user typed it: a whole number from 1 to 100, a
  /// trailing "%" allowed. Throws [FormatException] saying what to type
  /// instead.
  static int parsePercent(String text) {
    final trimmed = text.trim();
    final digits = trimmed.endsWith('%')
        ? trimmed.substring(0, trimmed.length - 1).trim()
        : trimmed;
    final value = int.tryParse(digits);
    if (value == null || !_isPercent(value)) {
      throw FormatException(
        '"$text" is not a percent. Give a whole number from 1 to 100.',
      );
    }
    return value;
  }

  /// This guard asking from [count] files on. Throws [FormatException]
  /// when [count] is below 1.
  MassDeleteGuard withMinFiles(int count) =>
      MassDeleteGuard(minFiles: count, percent: percent);

  /// This guard asking above [share] percent of a side. Throws
  /// [FormatException] outside 1 to 100.
  MassDeleteGuard withPercent(int share) =>
      MassDeleteGuard(minFiles: minFiles, percent: share);

  static bool _isMinFiles(int value) => value >= 1;

  static bool _isPercent(int value) => value >= 1 && value <= 100;

  @override
  bool operator ==(Object other) =>
      other is MassDeleteGuard &&
      other.minFiles == minFiles &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(minFiles, percent);

  @override
  String toString() => 'from $minFiles files and over $percent%';
}
