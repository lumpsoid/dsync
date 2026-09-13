import 'dart:io';

import 'package:dsync/cli/dsync_cli.dart';

/// Entrypoint of the CLI head (SPEC §3, §13). A thin shim: hand argv to
/// `lib/cli/`, set `exitCode`, nothing else — all CLI logic lives under
/// `lib/cli/`, which never imports `lib/app/` or `package:flutter`, so this
/// binary compiles without pulling in Flutter.
Future<void> main(List<String> argv) async {
  exitCode = await runDsyncCli(argv);
}
