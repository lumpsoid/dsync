import 'dart:io';

import 'package:dsync/cli/dsync_cli.dart';
import 'package:test/test.dart';

/// Closes the one part of task 67d911's point 1 `ad_hoc_sync_e2e_test.dart`
/// deliberately leaves open (see that file's own doc comment): that file
/// proves a file lands and both archives commit it, but a test that only
/// checks the file landed would still pass even if the archive were never
/// written at all — the next real run would then redo (or undo) the same
/// work forever.
///
/// The giveaway is a second run against the exact same trees: change
/// detection (SPEC §5.2) means the fast path finds every path's size/mtime
/// unchanged from what the first run archived, so the plan is empty and
/// nothing is applied. SPEC §8.2 goes one step further — "a run that
/// committed nothing does not compact" — so a correct second run does not
/// just exit 0, it never touches either archive file or the copy it already
/// made, at all. Both are asserted below, byte-for-byte and mtime-for-mtime,
/// rather than just re-checking the exit code.
void main() {
  group(
    'a second run against an unchanged pair is a true no-op (SPEC §5.2, §8.2)',
    () {
      late Directory tempDir;
      late Directory rootA;
      late Directory rootB;
      late Map<String, String> environment;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'dsync_idempotent_e2e_',
        );
        rootA = await Directory('${tempDir.path}/replica-a').create();
        rootB = await Directory('${tempDir.path}/replica-b').create();
        environment = {'XDG_STATE_HOME': '${tempDir.path}/state'};
      });

      tearDown(() async {
        await tempDir.delete(recursive: true);
      });

      Future<int> sync() => runDsyncCli(
        ['sync', rootA.path, rootB.path, '--batch'],
        environment: environment,
        workingDirectory: tempDir.path,
      );

      test(
        'exit 0 both times, and the second run leaves both archives and the '
        'copied file byte- and mtime-identical to what the first run wrote',
        () async {
          await File('${rootA.path}/hello.txt').writeAsString('hi there');

          expect(await sync(), 0);
          expect(
            await File('${rootB.path}/hello.txt').readAsString(),
            'hi there',
          );

          final archiveDir = Directory('${tempDir.path}/state/dsync');
          final archiveFiles =
              await archiveDir
                    .list()
                    .where((entity) => entity.path.endsWith('.jsonl'))
                    .toList()
                ..sort((a, b) => a.path.compareTo(b.path));
          expect(archiveFiles, hasLength(2));

          // Snapshot everything a stale-or-never-written archive would let
          // drift: both archives' exact bytes, and B's copy's own mtime
          // (SPEC §7.2/§7.4: only a copy ever sets it).
          final archiveContentsBefore = {
            for (final file in archiveFiles)
              file.path: await File(file.path).readAsBytes(),
          };
          final bStatBefore = await File('${rootB.path}/hello.txt').stat();

          // Second run: nothing on disk changed in between.
          expect(await sync(), 0);

          for (final file in archiveFiles) {
            expect(
              await File(file.path).readAsBytes(),
              archiveContentsBefore[file.path],
              reason:
                  '${file.path}: the fast path (SPEC §5.2) should have found '
                  'every path unchanged, so nothing was committed — and a '
                  'run that commits nothing does not compact (SPEC §8.2). '
                  'A change here means the second run redid work the first '
                  'run already archived.',
            );
          }

          final bStatAfter = await File('${rootB.path}/hello.txt').stat();
          expect(
            bStatAfter.modified,
            bStatBefore.modified,
            reason:
                'a no-op run must never rewrite the file it already '
                'copied.',
          );
          expect(bStatAfter.size, bStatBefore.size);
        },
      );
    },
  );
}
