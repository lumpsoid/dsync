// Runs `ScanProbe` over a directory on this machine (task 1a341e). Not part
// of the build.
//
//   dart run benchmark/scan_probe.dart <root>
//   dart run benchmark/scan_probe.dart <root> --passes 3 --ignore .git,build
//
// The phone is where the number that matters is measured —
// `integration_test/scan_probe_test.dart` is that entry point, and this one
// cannot substitute for it: a laptop differs from a phone in CPU *and*
// storage *and* OS at once, so a desktop figure separates nothing about
// Android.
//
// What it is for is the other half of task 1a341e's acceptance: every rung
// above `list+type+stat` is plain Dart, so whether one of them is doing
// algorithmic work it need not do — a glob recompiled per path, a redundant
// second `stat` — is answerable here, with a profiler easily attached, and
// anything found here helps the phone too. It answers "is there code waste",
// not "is the phone slow".
import 'dart:io';

import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/scan/scan_probe.dart';
import 'package:dsync/dsync_core/scan/scan_probe_format.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'usage: dart run benchmark/scan_probe.dart <root> '
      '[--passes N] [--ignore a,b]',
    );
    exitCode = 2;
    return;
  }

  final report = await ScanProbe().run(
    rootPath: positional.first,
    rules: RuleSet(ignore: _split(_flag(args, '--ignore'))),
    passes: int.tryParse(_flag(args, '--passes') ?? '') ?? 2,
  );
  stdout.write(formatScanProbe(report));
}

/// `--name value` or `--name=value`, or `null` when absent.
String? _flag(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}

List<String> _split(String? value) =>
    value == null || value.isEmpty ? const [] : value.split(',');
