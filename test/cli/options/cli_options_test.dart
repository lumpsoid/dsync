import 'package:dsync/cli/options/cli_options.dart';
import 'package:dsync/dsync_core/apply/applier.dart';
import 'package:dsync/cli/options/cli_options_error.dart';
import 'package:dsync/cli/options/sync_target.dart';
import 'package:dsync/cli/options/verbosity.dart';
import 'package:test/test.dart';

void main() {
  CliOptions build({
    SyncTarget? target,
    bool dryRun = false,
    bool batch = false,
    bool json = false,
    List<String> ignore = const [],
    List<String> sshOptions = const [],
    String? remoteCommand,
    bool verbose = false,
    bool quiet = false,
    String? warnSizeRaw,
    String? jobsRaw,
    String? applyConcurrencyRaw,
  }) {
    return CliOptions(
      target: target ?? const ProfileTarget('work'),
      dryRun: dryRun,
      batch: batch,
      json: json,
      ignore: ignore,
      sshOptions: sshOptions,
      remoteCommand: remoteCommand,
      verbose: verbose,
      quiet: quiet,
      warnSizeRaw: warnSizeRaw,
      jobsRaw: jobsRaw,
      applyConcurrencyRaw: applyConcurrencyRaw,
    );
  }

  group('CliOptions', () {
    test('the minimal valid combination constructs with defaults', () {
      final options = build();
      expect(options.dryRun, isFalse);
      expect(options.batch, isFalse);
      expect(options.json, isFalse);
      expect(options.ignore, isEmpty);
      expect(options.warnSizeBytes, isNull);
      expect(options.jobs, isNull);
      expect(options.sshOptions, isEmpty);
      expect(options.remoteCommand, isNull);
      expect(options.verbosity, Verbosity.normal);
    });

    test('--ssh-option keeps every value, in order (SPEC §4.2)', () {
      // One argv word per flag: an option value may contain spaces, so
      // nothing here splits or reorders what was typed.
      final options = build(
        sshOptions: const ['-i', '~/.ssh/id_ssshd', '-o', 'BatchMode=yes'],
      );

      expect(options.sshOptions, [
        '-i',
        '~/.ssh/id_ssshd',
        '-o',
        'BatchMode=yes',
      ]);
    });

    test('an empty --ssh-option is rejected', () {
      // It would reach ssh as an empty argv word, which ssh reads as a
      // second destination — a failure a long way from the flag.
      expect(
        () => build(sshOptions: const ['-p', '']),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('an empty --remote-dsync is rejected', () {
      expect(() => build(remoteCommand: ''), throwsA(isA<CliOptionsError>()));
    });

    test('--remote-dsync is null when absent, so a profile\'s own command '
        'survives the merge', () {
      expect(build().remoteCommand, isNull);
      expect(
        build(remoteCommand: '/opt/bin/dsync').remoteCommand,
        '/opt/bin/dsync',
      );
    });

    test('--verbose with --quiet is rejected', () {
      expect(
        () => build(verbose: true, quiet: true),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('--json without --batch or --dry-run is rejected', () {
      expect(() => build(json: true), throwsA(isA<CliOptionsError>()));
    });

    test('--json does not imply --batch: --json alone is rejected', () {
      // Regression for the explicit "it does NOT imply --batch" rule.
      expect(
        () => build(json: true, batch: false, dryRun: false),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('--json with --batch is accepted', () {
      final options = build(json: true, batch: true);
      expect(options.json, isTrue);
    });

    test('--json with --dry-run is accepted', () {
      final options = build(json: true, dryRun: true);
      expect(options.json, isTrue);
    });

    test('--batch with --dry-run is rejected', () {
      expect(
        () => build(batch: true, dryRun: true),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test(
      '--batch with status (dryRun forced true) is rejected the same way',
      () {
        // status has no --dry-run flag of its own; its Command always
        // passes dryRun: true, so this is the same rule as above, not a
        // second check.
        expect(
          () => build(batch: true, dryRun: true),
          throwsA(isA<CliOptionsError>()),
        );
      },
    );

    test('--jobs 0 is rejected', () {
      expect(() => build(jobsRaw: '0'), throwsA(isA<CliOptionsError>()));
    });

    test('--jobs negative is rejected', () {
      expect(() => build(jobsRaw: '-1'), throwsA(isA<CliOptionsError>()));
    });

    test('--jobs non-integer is rejected', () {
      expect(() => build(jobsRaw: 'four'), throwsA(isA<CliOptionsError>()));
    });

    test('--jobs a positive integer is accepted and parsed', () {
      final options = build(jobsRaw: '4');
      expect(options.jobs, 4);
    });

    test('--apply-concurrency absent is the Applier default', () {
      expect(build().applyConcurrency, Applier.defaultConcurrency);
    });

    test('--apply-concurrency a positive integer is accepted and parsed', () {
      expect(build(applyConcurrencyRaw: '4').applyConcurrency, 4);
    });

    test('--apply-concurrency zero or non-integer is rejected', () {
      expect(
        () => build(applyConcurrencyRaw: '0'),
        throwsA(isA<CliOptionsError>()),
      );
      expect(
        () => build(applyConcurrencyRaw: 'four'),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('--warn-size negative is rejected', () {
      expect(() => build(warnSizeRaw: '-1'), throwsA(isA<CliOptionsError>()));
    });

    test('--warn-size non-integer is rejected', () {
      expect(() => build(warnSizeRaw: 'big'), throwsA(isA<CliOptionsError>()));
    });

    test('--warn-size zero is accepted', () {
      final options = build(warnSizeRaw: '0');
      expect(options.warnSizeBytes, 0);
    });

    test('--warn-size a positive integer is accepted and parsed', () {
      final options = build(warnSizeRaw: '1048576');
      expect(options.warnSizeBytes, 1048576);
    });

    test('--ignore is carried through additively, in order', () {
      final options = build(ignore: ['*.tmp', '.git']);
      expect(options.ignore, ['*.tmp', '.git']);
    });
  });
}
