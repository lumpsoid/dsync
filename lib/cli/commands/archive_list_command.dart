import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dsync/dsync_core/archive/archive_inventory.dart';
import 'package:dsync/dsync_core/models/stored_archive.dart';
import 'package:dsync/dsync_core/state_dir.dart';

import '../options/state_dir_option.dart';

/// `dsync archive list` (SPEC §8.1, §8.3, §11.1) — every archive log this
/// host keeps and what each one costs on disk. Read-only.
///
/// `--json` per SPEC §11.4, for the same reason `pair list` carries one: a
/// list of files and sizes is exactly what a wrapper script wants to read.
/// One JSON object per line, then one `archiveTotal` line — the total is a
/// fact about the answer, not about any one archive, and a reader that only
/// wants the sum should not have to add up the rows to get it.
///
/// Sizes are plain byte counts in both modes, as everywhere else on this
/// CLI's output (`human_renderer.dart` prints `N byte(s)` for a plan).
class ArchiveListCommand extends Command<int> with StateDirOption {
  @override
  final name = 'list';

  @override
  final description =
      'List the archive logs this host keeps, and what they cost on disk.';

  static const _flagJson = 'json';

  final Map<String, String> environment;
  final StateDirPlatform platform;
  final IOSink out;

  ArchiveListCommand({
    required this.environment,
    required this.platform,
    IOSink? out,
  }) : out = out ?? stdout {
    addStateDirOption();
    argParser.addFlag(
      _flagJson,
      negatable: false,
      help: 'Machine-readable output (JSON Lines) on stdout (SPEC §11.4).',
    );
  }

  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException('dsync archive list takes no arguments.');
    }

    final stateDir = stateDirOr(platform);
    final archives = await ArchiveInventory.forStateDir(
      environment: environment,
      platform: stateDir,
    ).list();
    final total = archives.fold(0, (sum, a) => sum + a.sizeBytes);

    if (argResults!.flag(_flagJson)) {
      for (final archive in archives) {
        out.writeln(jsonEncode(_archiveToJson(archive)));
      }
      out.writeln(
        jsonEncode({
          'type': 'archiveTotal',
          'count': archives.length,
          'sizeBytes': total,
        }),
      );
    } else if (archives.isEmpty) {
      out.writeln('No archives.');
    } else {
      for (final archive in archives) {
        out.writeln(
          '${archive.profileId}  ${archive.side}  '
          '${archive.sizeBytes} byte(s)  '
          'root: ${archive.rootPath ?? '(no readable header)'}  '
          'last commit: ${archive.lastModified.toIso8601String()}',
        );
      }
      out.writeln('${archives.length} archive(s), $total byte(s) total.');
    }
    return 0; // SPEC §11.5: listing never fails on its own account.
  }
}

/// One [StoredArchive] as it appears on a `--json` line. `rootPath` is the
/// one field that can be absent, and it is written as `null` rather than
/// omitted: "this log's header could not be read" is the fact a reader most
/// needs from this list, not a missing key to infer it from.
Map<String, dynamic> _archiveToJson(StoredArchive archive) => {
  'type': 'archive',
  'profileId': archive.profileId,
  'side': archive.side,
  'logPath': archive.logPath,
  'rootPath': archive.rootPath,
  'sizeBytes': archive.sizeBytes,
  'lastModified': archive.lastModified.toIso8601String(),
};
