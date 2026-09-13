import 'package:dsync/cli/options/cli_options_error.dart';
import 'package:dsync/cli/options/verbosity.dart';
import 'package:test/test.dart';

void main() {
  group('Verbosity.resolve', () {
    test('neither flag set resolves to normal', () {
      expect(Verbosity.resolve(verbose: false, quiet: false), Verbosity.normal);
    });

    test('--verbose resolves to verbose', () {
      expect(Verbosity.resolve(verbose: true, quiet: false), Verbosity.verbose);
    });

    test('--quiet resolves to quiet', () {
      expect(Verbosity.resolve(verbose: false, quiet: true), Verbosity.quiet);
    });

    test('--verbose with --quiet is rejected (SPEC §11.5)', () {
      expect(
        () => Verbosity.resolve(verbose: true, quiet: true),
        throwsA(isA<CliOptionsError>()),
      );
    });
  });
}
