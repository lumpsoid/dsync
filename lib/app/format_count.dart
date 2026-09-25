/// A count as a page shows it, grouped in threes: "1,200". `intl` is not a
/// dependency (see `format_bytes.dart`), and a five-figure count read
/// without separators is a number nobody takes in at a glance.
String formatCount(int count) {
  final digits = count.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
