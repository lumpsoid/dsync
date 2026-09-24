// Runs a before/after comparison as interleaved pairs over `peer://`, with a
// radio snapshot at the start and end of every run (task 84fc92). Not part of
// the build. SPEC §14.1 has the procedure; this header has the flags.
//
//   dart run benchmark/interleaved_pairs.dart \
//     --profile bench --tree ~/sync/bench/synth \
//     --arm before=/tmp/dsync-before --arm after=/tmp/dsync-after
//
// Why. The phone <-> desktop link drifts between runs by ~13% on a phase
// total, which is more than most of the changes this project measures. Runs of
// the two arms taken in separate sittings compare two airs as much as two
// builds; alternated in one sitting they share it. The radio snapshot either
// side of each run is the check that they did.
//
// What one run is. `<arm command> sync <profile> --batch --timings`, driven
// from the desktop, with the phone serving (its Serve page, or `dsync agent
// --serve`). The profile's desktop root must contain --tree, which must be
// empty or absent: the driver owns it for the session and leaves it empty.
// Before the first run, and after every --switch, one file is synced into
// the phone and away again, untimed, so a phone that cannot write into the
// share stops the session before it is timed. Any sync with a failed action
// stops it too.
//
//   --pass fresh      each run pulls a new tree, `<tree>/run-NN`, created
//                     untimed before it; after the run the tree is deleted and
//                     an untimed sync carries the deletes to the phone, so
//                     every run creates into the same empty layout.
//   --pass overwrite  one tree, `<tree>/base`, seeded by an untimed sync; each
//                     run first rewrites every file (synthetic_tree.dart
//                     modify), so the run overwrites all of them.
//
// Trees. `--files` (3000) and `--per-dir` (30) shape each timed tree;
// `--mean-bytes` sets its mean file size, and when omitted synthetic_tree.dart
// keeps its own default, SPEC §5.3's mean. The one-file probe is always
// drawn at that default.
//
// Arms. `--arm name=command` twice, in the order the ratio is taken (second
// over first). The command is split on spaces and must run the dsync CLI —
// usually a binary from `dart compile exe bin/dsync.dart` at each commit. An
// arm that lives on the *phone* (a different APK) gets `--switch
// name=command` too: it is run through `sh -c` whenever the session moves to
// that arm, and the driver then waits for Enter, since the phone's Serve page
// has to be started by hand after an install. `--order abba` halves the
// switches, and cancels a drift that is linear in time as well.
//
// Output. `$HOME/.cache/dsync/scratch/pairs/<time>/`: each run's full stdout
// and `--timings` report, each raw radio capture, and `summary.txt`, rewritten
// after every run so a session cut short still has one. **The raw captures
// hold the network name, BSSID and addresses**; the summary does not.
//
// The adb device is adb's own choice; set ANDROID_SERIAL to pick one.
import 'dart:io';

import 'package:args/args.dart';

import 'pairs/pair_order.dart';
import 'pairs/pair_report.dart';
import 'pairs/pair_run.dart';
import 'pairs/radio_snapshot.dart';
import 'pairs/run_counts.dart';
import 'pairs/run_timings.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('profile', mandatory: true)
    ..addOption('tree', mandatory: true)
    ..addOption('pass', allowed: ['fresh', 'overwrite'], defaultsTo: 'fresh')
    ..addOption('pairs', defaultsTo: '3')
    ..addOption('files', defaultsTo: '3000')
    ..addOption('per-dir', defaultsTo: '30')
    ..addOption('mean-bytes')
    ..addOption(
      'order',
      allowed: [for (final order in PairOrder.values) order.name],
      defaultsTo: PairOrder.abab.name,
    )
    ..addMultiOption('arm', splitCommas: false)
    ..addMultiOption('switch', splitCommas: false)
    ..addOption('out');
  final ArgResults options;
  try {
    options = parser.parse(args);
  } on FormatException catch (error) {
    _fail('${error.message}\n\n${parser.usage}');
  }

  final arms = _named(options.multiOption('arm'));
  if (arms.length != 2) _fail('give exactly two --arm name=command');
  final names = arms.keys.toList();
  final pairs = int.parse(options.option('pairs')!);
  if (pairs < 1) _fail('--pairs must be at least 1');
  final switches = _named(options.multiOption('switch'));
  for (final name in switches.keys) {
    if (!arms.containsKey(name)) _fail('--switch names no arm: $name');
  }

  final session = _Session(
    profile: options.option('profile')!,
    tree: Directory(_expandHome(options.option('tree')!)),
    fresh: options.option('pass') == 'fresh',
    files: int.parse(options.option('files')!),
    perDir: int.parse(options.option('per-dir')!),
    meanBytes: switch (options.option('mean-bytes')) {
      final value? => int.parse(value),
      null => null,
    },
    names: names,
    commands: [for (final name in names) arms[name]!.split(' ')],
    switches: [for (final name in names) switches[name]],
    order: PairOrder.values.byName(options.option('order')!),
    pairs: pairs,
    out: Directory(
      _expandHome(
        options.option('out') ??
            '~/.cache/dsync/scratch/pairs/'
                '${DateTime.now().toIso8601String().replaceAll(':', '-')}',
      ),
    ),
  );
  await session.run();
}

/// One sitting: the arms, the tree it owns, and the order it runs them in.
/// The one place the per-run sequence — switch, prepare, snapshot, sync,
/// snapshot, clean up — is written down.
class _Session {
  _Session({
    required this.profile,
    required this.tree,
    required this.fresh,
    required this.files,
    required this.perDir,
    required this.meanBytes,
    required this.names,
    required this.commands,
    required this.switches,
    required this.order,
    required this.pairs,
    required this.out,
  });

  final String profile;
  final Directory tree;
  final bool fresh;
  final int files;
  final int perDir;

  /// The timed trees' mean file size; null leaves synthetic_tree.dart's own.
  final int? meanBytes;
  final List<String> names;
  final List<List<String>> commands;
  final List<String?> switches;
  final PairOrder order;
  final int pairs;
  final Directory out;

  final _runs = <PairRun>[];

  Future<void> run() async {
    if (tree.existsSync() && tree.listSync().isNotEmpty) {
      _fail('${tree.path} must be empty or absent: the session owns it');
    }
    out.createSync(recursive: true);
    stdout.writeln('session folder: ${out.path}');
    if (await _radio('preflight') == null) {
      _fail(
        'no radio snapshot: is the phone attached over adb, authorised, and '
        'on Wi-Fi? See ${out.path}/preflight.*',
      );
    }

    int? current;
    for (final (index, arm) in order.sequence(pairs).indexed) {
      final tag = 'run-${'${index + 1}'.padLeft(2, '0')}';
      if (arm != current) {
        await _switchTo(arm);
        if (current == null || switches[arm] != null) {
          await _probeWrite(arm, tag);
        }
        current = arm;
      }
      final Directory runTree;
      if (fresh) {
        runTree = Directory('${tree.path}/$tag');
        await _createTree(runTree);
      } else {
        runTree = Directory('${tree.path}/base');
        if (index == 0) {
          await _createTree(runTree);
          await _sync(arm, 'seed');
        }
        await _syntheticTree(['modify', runTree.path, '--round', '1']);
      }

      stdout.writeln('$tag: ${names[arm]}');
      final radioStart = await _radio('$tag-start');
      final synced = await _sync(arm, '$tag-${names[arm]}');
      final radioEnd = await _radio('$tag-end');
      final timings = RunTimings.parse(synced.report);
      if (timings == null) {
        _fail('$tag printed no --timings report; see ${out.path}');
      }
      final applied = synced.counts.applied;
      _runs.add(
        PairRun(
          arm: arm,
          timings: timings,
          applied: applied,
          radioStart: radioStart,
          radioEnd: radioEnd,
        ),
      );
      if (usualApplied(_runs) case final usual? when applied != usual) {
        stdout.writeln(
          'warning: $tag applied $applied actions where the session\'s other '
          'runs applied $usual; it is flagged in the summary',
        );
      }
      _writeSummary();

      if (fresh) {
        runTree.deleteSync(recursive: true);
        await _sync(arm, '$tag-cleanup');
      }
    }
    if (!fresh) {
      Directory('${tree.path}/base').deleteSync(recursive: true);
      await _sync(order.sequence(pairs).last, 'cleanup');
    }
    stdout
      ..write(_writeSummary())
      ..writeln('session folder: ${out.path}');
  }

  String _writeSummary() {
    final text = renderPairReport(
      arms: names,
      order: order,
      pass: fresh ? 'fresh' : 'overwrite',
      runs: _runs,
    );
    File('${out.path}/summary.txt').writeAsStringSync(text);
    return text;
  }

  Future<void> _switchTo(int arm) async {
    final command = switches[arm];
    if (command == null) return;
    stdout.writeln('switching to ${names[arm]}: $command');
    final process = await Process.start('sh', [
      '-c',
      command,
    ], mode: ProcessStartMode.inheritStdio);
    if (await process.exitCode != 0) _fail('switch to ${names[arm]} failed');
    stdout.write(
      'Switched to ${names[arm]}. Start serving on the phone, then press '
      'Enter: ',
    );
    stdin.readLineSync();
  }

  /// One sync with [arm]'s binary, its output saved under [label]. Returns
  /// the `--timings` report, which the CLI prints on stderr, and the counts
  /// of its stdout summary. Any failed action ends the session: a run whose
  /// writes failed timed nothing, and the untimed syncs around it leave the
  /// tree in a state the next run would time instead.
  Future<({String report, RunCounts counts})> _sync(
    int arm,
    String label,
  ) async {
    final command = commands[arm];
    final result = await Process.run(command.first, [
      ...command.skip(1),
      'sync',
      profile,
      '--batch',
      '--timings',
    ]);
    File(
      '${out.path}/$label.txt',
    ).writeAsStringSync('${result.stdout}\n--- stderr ---\n${result.stderr}');
    final counts = RunCounts.parse(result.stdout as String);
    if (counts != null && counts.failed > 0) {
      _fail(
        '$label: ${counts.failed} actions failed (${counts.applied} applied), '
        'so it is no timing; is the phone\'s All-files grant still there? '
        'See ${out.path}/$label.txt',
      );
    }
    if (result.exitCode != 0) {
      _fail(
        '$label: dsync exited ${result.exitCode}; see ${out.path}/$label.txt',
      );
    }
    if (counts == null) {
      _fail('$label printed no summary line; see ${out.path}/$label.txt');
    }
    return (report: result.stderr as String, counts: counts);
  }

  /// Syncs one file into the phone and back out, untimed, so a phone that
  /// cannot write into the share (no All-files grant, a wiped install) stops
  /// the session before a run times it. Run before the first run and after
  /// every switch, since an install is what loses the grant.
  Future<void> _probeWrite(int arm, String tag) async {
    final label = '$tag-probe-${names[arm]}';
    final probe = Directory('${tree.path}/probe');
    await _syntheticTree([
      'create',
      probe.path,
      '--files',
      '1',
      '--per-dir',
      '1',
    ]);
    final written = await _sync(arm, label);
    if (written.counts.applied == 0) {
      _fail(
        '$label: the probe file was not synced; is --tree inside the '
        'profile\'s desktop root? See ${out.path}/$label.txt',
      );
    }
    probe.deleteSync(recursive: true);
    await _sync(arm, '$label-cleanup');
  }

  /// Captures `cmd wifi status` and `dumpsys wifi` as they are, then parses
  /// them. A failed capture is an empty text, which parses to null.
  Future<RadioSnapshot?> _radio(String label) async {
    Future<String> capture(String name, List<String> command) async {
      try {
        final result = await Process.run('adb', ['shell', ...command]);
        final text = '${result.stdout}';
        File(
          '${out.path}/$label.$name.txt',
        ).writeAsStringSync(result.exitCode == 0 ? text : '${result.stderr}');
        return result.exitCode == 0 ? text : '';
      } on ProcessException catch (error) {
        File('${out.path}/$label.$name.txt').writeAsStringSync('$error');
        return '';
      }
    }

    return RadioSnapshot.parse(
      wifiStatus: await capture('wifi-status', ['cmd', 'wifi', 'status']),
      dumpsys: await capture('dumpsys-wifi', ['dumpsys', 'wifi']),
    );
  }

  Future<void> _createTree(Directory at) => _syntheticTree([
    'create',
    at.path,
    '--files',
    '$files',
    '--per-dir',
    '$perDir',
    if (meanBytes case final mean?) ...['--mean-bytes', '$mean'],
  ]);

  Future<void> _syntheticTree(List<String> args) async {
    final script = File.fromUri(Platform.script.resolve('synthetic_tree.dart'));
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      script.path,
      ...args,
    ]);
    if (result.exitCode != 0) {
      _fail('synthetic_tree ${args.first} failed:\n${result.stderr}');
    }
  }
}

/// `name=command` options as a map, in the order given.
Map<String, String> _named(List<String> values) {
  final named = <String, String>{};
  for (final value in values) {
    final at = value.indexOf('=');
    if (at <= 0) _fail('expected name=command, got: $value');
    named[value.substring(0, at)] = value.substring(at + 1);
  }
  return named;
}

String _expandHome(String path) => path.startsWith('~/')
    ? '${Platform.environment['HOME']}${path.substring(1)}'
    : path;

Never _fail(String message) {
  stderr.writeln('interleaved_pairs: $message');
  exit(1);
}
