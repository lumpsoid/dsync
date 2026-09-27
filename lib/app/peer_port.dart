/// The TCP port this device serves paired devices on, and the one its
/// pairing codes tell them to dial (SPEC §4.4): 1 to 65535, nothing else.
///
/// A value rather than an `int` so the range is checked once, where the
/// value is made — at the Settings page's field and at the settings
/// store's parse — and nothing downstream re-decides it.
final class PeerPort {
  const PeerPort._(this.value);

  /// [value] as a port. Throws [FormatException] outside 1–65535.
  factory PeerPort(int value) {
    if (value < 1 || value > 65535) {
      throw FormatException('$value is not a port; give one from 1 to 65535.');
    }
    return PeerPort._(value);
  }

  /// A port as the user typed it: a whole number from 1 to 65535. Throws
  /// [FormatException] saying what to type instead.
  factory PeerPort.parse(String text) {
    final value = int.tryParse(text.trim());
    if (value == null || value < 1 || value > 65535) {
      throw FormatException(
        '"$text" is not a port. Give a whole number from 1 to 65535.',
      );
    }
    return PeerPort._(value);
  }

  final int value;

  @override
  bool operator ==(Object other) => other is PeerPort && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}
