import 'dart:io';

/// The `ssh` this machine already has up, whatever shape that is.
///
/// Shared by `real_ssh_e2e_test.dart` and the remote half of
/// `convergence_soak_test.dart`: both want one session against a real sshd,
/// and neither can assume the stereotype this suite used to — a TCP host
/// answering on port 22, addressed as `host:path`, with `dsync` on the login
/// PATH. A machine may instead have a socket-activated sshd reached as
/// `unix/run/ssh-unix-local/socket`, or a destination only `~/.ssh/config`
/// can resolve.
///
/// Which of those a machine has cannot be discovered by guessing, and
/// guessing is what SPEC §4.1's `ssh://` form exists to stop (task 50de3d).
/// So [destinationVariable] names it and this only checks that what it names
/// works; unset, the loopback default keeps the behaviour the suite had
/// before.
///
/// Nothing here needs `dsync` on the remote PATH: a caller compiles the
/// binary and names it with `--remote-dsync` (SPEC §4.2, §11.2), which is
/// the precondition this used to have no workaround for.
sealed class RealSsh {
  /// `DSYNC_SSH_DESTINATION`: anything `ssh` accepts as its destination —
  /// `me@host`, a `Host` alias, `unix/run/ssh-unix-local/socket`.
  static const destinationVariable = 'DSYNC_SSH_DESTINATION';

  /// `DSYNC_SSH_OPTIONS`: whitespace-separated options that destination
  /// needs, e.g. `-i ~/.ssh/id_ssshd` or `-p 2222`. An option value
  /// containing a space cannot be given this way; `~/.ssh/config` can say it
  /// instead.
  static const optionsVariable = 'DSYNC_SSH_OPTIONS';

  /// Loopback, the shape most machines with an sshd have, used when
  /// [destinationVariable] is unset. Not `localhost`: SPEC §4.1 sends that
  /// literal string in-process, and while the `ssh://` form now overrides
  /// that, an address keeps the two tests honest about reaching a *remote*
  /// replica.
  static const defaultDestination = '127.0.0.1';

  /// Whether [destinationVariable] names a destination to try.
  ///
  /// Free, unlike [probe] — which spends a connection attempt — so a caller
  /// that only wants real ssh when it was asked for can check this first.
  static bool get isConfigured =>
      Platform.environment[destinationVariable] != null;

  /// Tries the configured destination (or [defaultDestination]) and reports
  /// what it found.
  ///
  /// Two things are checked, apart, so a failure names its own cause rather
  /// than "ssh did not work":
  ///
  /// 1. a non-interactive connection that needs no password and no host-key
  ///    answer;
  /// 2. the far end seeing this machine's `Directory.systemTemp`, since both
  ///    callers put their replica roots there and read them back here. It
  ///    normally does, being this machine; an sshd unit hardened with
  ///    `PrivateTmp=yes` is the case that breaks it.
  static Future<RealSsh> probe() async {
    final environment = Platform.environment;
    final destination = environment[destinationVariable] ?? defaultDestination;
    final options = (environment[optionsVariable] ?? '').split(RegExp(r'\s+'))
      ..removeWhere((option) => option.isEmpty);
    // Never a prompt: a password or host-key question would hang the suite
    // rather than fail it. Carried into `SshAvailable.options` too, so the
    // run under test is as unable to block as this probe is.
    final safeOptions = [
      ...options,
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=5',
    ];

    final ProcessResult reachable;
    try {
      reachable = await _run(safeOptions, destination, ['true']);
    } on ProcessException catch (error) {
      return SshUnavailable('no `ssh` to run: ${error.message}');
    }
    if (reachable.exitCode != 0) {
      return SshUnavailable(
        'cannot ssh to "$destination" non-interactively (exit '
        '${reachable.exitCode}). Set $destinationVariable (and '
        '$optionsVariable, if it needs options) to an ssh this machine '
        'already answers on — a Host alias or '
        '"unix/run/ssh-unix-local/socket" both count.'
        '${_trailingStderr(reachable)}',
      );
    }

    // A directory of its own, not a name built from the pid: two suites in
    // the same test process probe concurrently, and a shared marker path has
    // one of them deleting the file the other is still asking about.
    final markerDir = await Directory.systemTemp.createTemp('dsync_ssh_probe_');
    try {
      final marker = await File('${markerDir.path}/marker')
          .writeAsString('probe');
      final shared = await _run(safeOptions, destination, [
        'test',
        '-f',
        marker.path,
      ]);
      if (shared.exitCode != 0) {
        return SshUnavailable(
          'an ssh session to "$destination" does not see ${marker.path}, so '
          'the replica roots these tests create would not exist on the far '
          'end — a private /tmp for sshd would do that.',
        );
      }
    } finally {
      await markerDir.delete(recursive: true);
    }

    return SshAvailable(destination: destination, options: safeOptions);
  }

  static Future<ProcessResult> _run(
    List<String> options,
    String destination,
    List<String> remoteCommand,
  ) => Process.run('ssh', [...options, '-T', destination, ...remoteCommand]);

  static String _trailingStderr(ProcessResult result) {
    final text = (result.stderr as String).trim();
    return text.isEmpty ? '' : '\nssh said: $text';
  }
}

/// An ssh this machine answers on, and what it takes to reach it.
final class SshAvailable extends RealSsh {
  /// Handed to `ssh` as its destination, and to dsync inside an `ssh://`
  /// location — see [locationFor].
  final String destination;

  /// What `--ssh-option` has to carry for this destination (SPEC §11.2).
  final List<String> options;

  SshAvailable({required this.destination, required this.options});

  /// [path] on the far side, as a location (SPEC §2).
  ///
  /// Always the `ssh://` form: [destination] may be a shape the `host:path`
  /// rule cannot express, and it must classify remote (SPEC §4.1) even
  /// though it leads back to this very machine — which is the whole point of
  /// running a real ssh session against it.
  String locationFor(String path) => 'ssh://$destination:$path';

  /// What `--remote-dsync` has to carry for the far side to run [binary]
  /// against its own [stateHome] (SPEC §4.2, §8.3).
  ///
  /// `ssh` joins its command arguments back into one string for the remote
  /// shell, so a `VAR=value` prefix works as written — which is what lets a
  /// test own the archive and lock the far end writes, instead of reaching
  /// into the real state directory of whoever ran the suite.
  String remoteCommandFor({
    required String binary,
    required String stateHome,
  }) => 'XDG_STATE_HOME=$stateHome $binary';
}

/// Why this machine cannot run a real-ssh test.
final class SshUnavailable extends RealSsh {
  final String reason;

  SshUnavailable(this.reason);
}
