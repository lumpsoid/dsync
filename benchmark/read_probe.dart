// Runs `ReadProbe` over a directory on this machine (task 8347dd). Not part
// of the build.
//
//   dart run benchmark/read_probe.dart <root>
//   dart run benchmark/read_probe.dart <root> --files 2000 --depths 1,4,16
//
// The phone is where the number that matters is measured — the app's
// Diagnostics page is that entry point, and this one cannot substitute for
// it: a laptop differs from a phone in CPU *and* storage *and* OS at once,
// and on Android the read path goes through emulated storage besides.
//
// What it is for is the control. The question this probe asks is whether the
// limit on how fast files are read is the device or `dart:io`'s asynchronous
// path, and a desktop answers half of it: if the synchronous-in-isolates mode
// beats the asynchronous ones here too, on storage nobody would call slow,
// then the gap is the dispatch and not the phone.
import 'dart:io';

import 'package:dsync/dsync_core/probe/read_probe.dart';
import 'package:dsync/dsync_core/probe/read_probe_format.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'usage: dart run benchmark/read_probe.dart <root> '
      '[--files N] [--depths a,b,c]',
    );
    exitCode = 2;
    return;
  }

  final files = int.tryParse(_flag(args, '--files') ?? '');
  final depths = _depths(_flag(args, '--depths'));

  final report =
      await ReadProbe(fileLimit: files ?? const ReadProbe().fileLimit).run(
        rootPath: positional.first,
        depths: depths ?? ReadProbe.defaultDepths,
        // Printed as they land: the sweep is `modes × depths` full passes and a
        // script that prints nothing until the end looks hung.
        onSample: (sample) => stderr.writeln(
          '  ${sample.mode.name} depth ${sample.depth}: '
          '${sample.elapsed.inMilliseconds} ms',
        ),
      );

  stdout.write(formatReadProbe(report));
}

String? _flag(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

List<int>? _depths(String? value) {
  if (value == null) return null;
  final parsed = [
    for (final part in value.split(',')) ?int.tryParse(part.trim()),
  ];
  return parsed.isEmpty ? null : parsed;
}
