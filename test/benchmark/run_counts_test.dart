import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/pairs/run_counts.dart';

void main() {
  test('reads applied and failed from the summary line among the output', () {
    // The line as HumanRenderer._renderSummary prints it.
    const output =
        '  [3000/3000]\n'
        'summary: applied=0 skipped=0 conflicts=0 failed=3000 unreadable=0\n';

    final counts = RunCounts.parse(output)!;

    expect(counts.applied, 0);
    expect(counts.failed, 3000);
  });

  test('output with no summary line is null', () {
    expect(RunCounts.parse('error: cannot reach the phone\n'), isNull);
  });
}
