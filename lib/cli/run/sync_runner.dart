import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/run/run_controller.dart';
import 'package:dsync/dsync_core/state_dir.dart';
import 'package:path/path.dart' as p;

import '../agents/connected_replicas.dart';
import '../agents/local_addresses.dart';
import '../exit_code.dart';
import '../options/cli_options.dart';
import '../options/effective_options.dart';
import '../options/sync_target.dart';
import '../output/human_renderer.dart';
import '../output/json_renderer.dart';
import '../presenter/batch_presenter.dart';
import '../presenter/dry_run_presenter.dart';
import '../presenter/interactive_presenter.dart';
import '../profile/profile_loader.dart';
import 'interrupt_guard.dart';

/// The run step `SyncCommand` and `StatusCommand`
/// (`lib/cli/commands/sync_command.dart`, `status_command.dart`) each take as
/// a constructor callback and call once they have parsed their own
/// [CliOptions].
///
/// A callback rather than an interface, and rather than each command
/// importing [SyncRunner] and calling it directly, for the same reason
/// [RunController]'s `Presenter` typedef and `AgentServer.serve`'s
/// `Agent Function(ReplicaSpec)` callback are both this same shape: it lets
/// `DsyncCommandRunner` (`lib/cli/dsync_cli.dart`) wire in a real
/// [SyncRunner.run] while a parsing-only test hands each command a recording
/// fake instead — one that captures the [CliOptions] it was called with and
/// returns a plain `0` — so asserting what `argv` parsed to never has to
/// drive a real run (loading a profile, connecting an agent) just to reach
/// it.
typedef RunSync = Future<int> Function(CliOptions options);

/// The one owner of a `sync`/`status` run's ordering (SPEC §11; CLAUDE.md
/// "One owner for cross-module ordering"): resolve the target → connect both
/// replica agents → pick a presenter and a renderer → drive
/// `RunController.run()`, watching for SIGINT alongside it (task fc661b) →
/// resolve the exit code (SPEC §11.5).
///
/// A concrete, single-implementation class with no interface, in the same
/// spirit as `RunController` itself and `DsyncCommandRunner`
/// (`lib/cli/dsync_cli.dart`): every step's real logic already lives in its
/// own tested component ([loadProfile], [EffectiveOptions],
/// [resolveReplicaAgents], the presenters, the renderers, [RunController]);
/// this class only calls them in the right order and turns the result into
/// an exit code. `SyncCommand` and `StatusCommand` (`lib/cli/commands/`)
/// each only build their own [CliOptions] (`status` with [CliOptions.dryRun]
/// forced `true`), then call [run] through the [RunSync] callback
/// `DsyncCommandRunner` hands both of them — `status` needs no branch of its
/// own here, either, since SPEC §11.1 makes it `sync --dry-run` under a
/// friendlier name all the way down to [CliOptions].
///
/// SPEC §11.4's run header — which replicas, and what the tool already
/// knows about the pair (task ee190c) — needs no extra call here: it rides
/// the same [RunEvent] stream as everything else, as a `RunReplicasEvent`
/// `RunController.run()` yields right after both `hello()`s succeed. This
/// class's only job for it is threading [EffectiveOptions.profileId] and
/// [ConnectedReplicas]'s diagnostics into whichever renderer gets built
/// below, alongside the context each already receives.
class SyncRunner {
  /// The process environment, threaded through rather than read from
  /// [Platform.environment] directly, so a caller (`runDsyncCli`, or a test)
  /// can supply an isolated one — the same convention [loadProfile],
  /// [EffectiveOptions], and [resolveReplicaAgents] already use.
  final Map<String, String> environment;

  /// Which SPEC §8.3 rule resolves a replica's state directory (archive,
  /// lock, and — for a `peer://` side — the device identity and
  /// paired-device store), threaded through for the same reason
  /// [environment] is: `runDsyncCli` supplies the real host's answer
  /// (`hostStateDirPlatform()`), a test supplies whichever of the five it
  /// wants to exercise.
  final StateDirPlatform platform;

  /// How this host's own filesystem paths are spelled (SPEC §3's read-side
  /// path conversion), threaded through for the same reason [platform] is:
  /// `runDsyncCli` supplies the real host's answer (`hostPathStyle()`), a
  /// test supplies whichever `package:path` `Style` it wants to exercise.
  /// Only a local replica's own `Scanner` ever reads it
  /// (`resolveReplicaAgents`) — a remote replica's agent process resolves
  /// its own host's style independently, the same way it resolves its own
  /// `platform` independently (`agent_command.dart`'s `_buildAgent`).
  final p.Style pathStyle;

  /// The process's current working directory, for resolving a relative
  /// local ad-hoc path (see [EffectiveOptions.forAdHoc]'s doc comment).
  final String workingDirectory;

  /// The one piece of real I/O this needs beyond [environment] — see
  /// [resolveReplicaAgents]'s own doc comment. Overridable so a test can
  /// drive locality without a network.
  final Future<Set<String>> Function() localAddressLookup;

  /// The `ssh` binary to spawn for a remote replica (SPEC §4.2).
  /// Overridable so a test can point it at a script that fails instead of a
  /// real host.
  final String sshExecutable;

  /// Builds the [Presenter] the default (non-`--batch`, non-`--dry-run`)
  /// path uses (SPEC §11.3) — see [_choosePresenter]. Real callers never set
  /// this; it defaults to [_defaultInteractivePresenter], which is exactly
  /// what [_choosePresenter] built inline before this seam existed: an
  /// [InteractivePresenter] over the real [stdin]/[stdout].
  ///
  /// Overridable for the same reason [localAddressLookup] and
  /// [sshExecutable] are, and in the same shape as the [RunSync] typedef
  /// above: a real terminal is the one piece of this run a test cannot
  /// otherwise reach. `stdin.hasTerminal` is always `false` in a test
  /// process, which makes [InteractivePresenter] throw
  /// [NonInteractiveStdinError] before it ever reads a scripted answer — so
  /// there is no way to drive interactive review (accept / skip / resolve a
  /// conflict by direction) through a real [run] without this (task 67d911).
  /// A test hands in one built over a scripted `Stream<String>` and a
  /// buffering `IOSink`, with `isTerminal` forced `true`, instead of
  /// constructing `SyncRunner` some other way.
  final Presenter Function() buildInteractivePresenter;

  SyncRunner({
    required this.environment,
    required this.platform,
    required this.pathStyle,
    required this.workingDirectory,
    this.localAddressLookup = systemLocalAddresses,
    this.sshExecutable = 'ssh',
    Presenter Function()? buildInteractivePresenter,
  }) : buildInteractivePresenter =
           buildInteractivePresenter ?? _defaultInteractivePresenter;

  static Presenter _defaultInteractivePresenter() => InteractivePresenter(
    lines: stdin.transform(utf8.decoder).transform(const LineSplitter()),
    output: stdout,
    isTerminal: stdin.hasTerminal,
  ).call;

  /// Runs [options] to completion and returns the process exit code (SPEC
  /// §11.5).
  ///
  /// Anything thrown while resolving the target or connecting the replicas —
  /// a profile that does not parse, a lock already held, an unreachable
  /// replica — happens before any [RunController] exists and propagates to
  /// the caller (`dsync_cli.dart`'s catch-all maps it to exit 3, SPEC
  /// §11.5): nothing here adds a layer of catching around that. Once
  /// [RunController.run] is driving the stream, its own contract already
  /// turns any failure into a [RunErrorEvent] rather than a thrown
  /// exception, so the loop below never needs a second layer either — it
  /// only ever does the plain assignments SPEC §11.5's exit code is computed
  /// from, once, after the stream ends.
  ///
  /// task fc661b: a SIGINT received anywhere during the loop stops the run
  /// at the next action boundary — task e9f31c made every `RunEvent` one of
  /// those, by giving `Applier.apply` a per-action callback, so the check
  /// below is just [InterruptGuard.requested] — and always forces the exit
  /// code to [sigintExitCode] regardless of what [RunOutcome] would
  /// otherwise say, since the signal describes what the *user* did, not what
  /// the run did. A second SIGINT skips all of this and calls `exit`
  /// directly.
  Future<int> run(CliOptions options) async {
    final target = options.target;

    // SPEC §4.1: `EffectiveOptions.forAdHoc` uses locality to decide which
    // side is A, and `resolveReplicaAgents` uses it to decide local-vs-ssh.
    // Both must agree, so the address lookup — the one piece of real I/O
    // either needs — runs at most once here and the same result is handed
    // to both, rather than letting each reach for its own default. A
    // profile target never needs it for `EffectiveOptions.forProfile` (a
    // profile's `a`/`b` are never reordered), so only the ad-hoc branch
    // below ever calls [localAddressLookup].
    final EffectiveOptions effective;
    final Future<Set<String>> Function() sharedLocalAddressLookup;
    switch (target) {
      case ProfileTarget(:final name):
        final profile = await loadProfile(name, environment: environment);
        effective = EffectiveOptions.forProfile(
          profile,
          options,
          environment: environment,
          workingDirectory: workingDirectory,
        );
        sharedLocalAddressLookup = localAddressLookup;
      case AdHocTarget():
        final needsLocalAddresses =
            target.locationA.consultsLocalAddresses ||
            target.locationB.consultsLocalAddresses;
        final localAddresses = needsLocalAddresses
            ? await localAddressLookup()
            : const <String>{};
        effective = EffectiveOptions.forAdHoc(
          target,
          options,
          environment: environment,
          localAddresses: localAddresses,
          workingDirectory: workingDirectory,
        );
        sharedLocalAddressLookup = () async => localAddresses;
    }

    final connected = await resolveReplicaAgents(
      effective,
      environment: environment,
      platform: platform,
      pathStyle: pathStyle,
      localAddressLookup: sharedLocalAddressLookup,
      sshExecutable: sshExecutable,
    );

    final controller = RunController(
      agentA: connected.agentA,
      agentB: connected.agentB,
      presenter: _choosePresenter(options),
      rules: effective.rules,
    );

    // SPEC §11.1: an ad-hoc run has no profile name, so the run header (SPEC
    // §11.4, task ee190c) shows the derived id in a different place than a
    // profile run shows its name — see HumanRenderer.isAdHoc.
    final isAdHoc = target is AdHocTarget;

    final void Function(RunEvent) render;
    if (options.json) {
      render = JsonRenderer(
        out: stdout,
        err: stderr,
        profileId: effective.profileId,
        diagnosticsA: connected.diagnosticsA,
        diagnosticsB: connected.diagnosticsB,
      ).render;
    } else {
      final renderer = HumanRenderer(
        out: stdout,
        err: stderr,
        verbosity: options.verbosity,
        warnSizeBytes: effective.warnSizeBytes,
        rules: effective.rules,
        diagnosticsA: connected.diagnosticsA,
        diagnosticsB: connected.diagnosticsB,
        profileId: effective.profileId,
        isAdHoc: isAdHoc,
      );
      renderer.renderPreamble(); // no-op below Verbosity.verbose.
      render = renderer.render;
    }

    // task fc661b: a SIGINT stops the run between actions rather than
    // mid-copy. The one real signal subscription lives here, scoped to this
    // run — `dsync agent --stdio` (`AgentCommand`) never calls `SyncRunner`,
    // so it never installs one; it already exits cleanly on the EOF killing
    // its `ssh` gives it.
    final interrupt = InterruptGuard();
    late final StreamSubscription<ProcessSignal> sigintSubscription;
    sigintSubscription = ProcessSignal.sigint.watch().listen((_) {
      // A second SIGINT "exits immediately" (task fc661b): whatever grace
      // the first one bought — reaching the next safe point below — is over,
      // so this skips straight past `RunController.run()`'s own unlock/
      // disconnect `finally` blocks. That is fine: SPEC's own correction
      // that this task opens with is exactly why — the OS drops the file
      // lock when this process dies by any means, and `ssh` dying gives the
      // remote side's lock the same fate.
      if (interrupt.receiveSignal() == InterruptResponse.exitImmediately) {
        exit(sigintExitCode);
      }
    });

    RunSummaryEvent? summary;
    RunErrorEvent? error;
    var appliedAny = false;
    try {
      await for (final event in controller.run()) {
        render(event);
        switch (event) {
          case RunSummaryEvent e:
            summary = e;
          case RunErrorEvent e:
            error = e;
          case RunResultEvent():
            appliedAny = true;
          default:
            break;
        }

        // task e9f31c: every `RunEvent` is now a safe point to stop at —
        // `Applier.apply` reports each action as it finishes rather than
        // running the whole plan as one uninterruptible unit, so there is no
        // longer a "before the first action" restriction to check for. This
        // `break` cancels `controller.run()`'s subscription, which — because
        // `RunController.run()`'s generator is suspended exactly at a
        // `yield` when that happens — runs its unlock/disconnect `finally`
        // blocks exactly as a normal end of stream would, and (mid-apply)
        // leaves `Applier.apply` itself suspended at the action boundary it
        // had just reported, never starting the next one.
        if (interrupt.requested) break;
      }
    } finally {
      await sigintSubscription.cancel();
    }

    // task fc661b: report what was applied before stopping, rather than
    // just changing the exit code silently. `summary` only exists when the
    // whole plan finished applying (rendered above like any other event), so
    // there is nothing more to add there beyond noting *why* the exit code
    // is about to say "interrupted" instead of whatever this run actually
    // finished doing. task e9f31c added the middle case: stopped partway
    // through apply, after at least one `RunResultEvent` but before the
    // summary — `appliedAny` is what tells that apart from "never got to
    // apply at all".
    if (interrupt.requested) {
      stderr.writeln(switch ((summary != null, appliedAny)) {
        (true, _) =>
          'interrupted (SIGINT); this run had already finished applying '
              '— see summary above.',
        (false, true) =>
          'interrupted (SIGINT) partway through applying — see the '
              'results above for what already landed; the rest of the '
              'plan was not attempted.',
        (false, false) =>
          'interrupted (SIGINT) before applying any '
              'changes.',
      });
    }

    return RunOutcome(
      summary: summary,
      error: error,
      interrupted: interrupt.requested,
    ).exitCode;
  }

  /// SPEC §11.1, §11.3: dry-run (which includes `status`) never applies
  /// anything; `--batch` applies every non-conflicting action unasked;
  /// otherwise the default is interactive, via [buildInteractivePresenter] —
  /// `--batch` and `--dry-run` cannot both be set ([CliOptions] already
  /// rejects that combination), so this is a plain if-chain, not a validated
  /// priority order.
  Presenter _choosePresenter(CliOptions options) {
    if (options.dryRun) return const DryRunPresenter().call;
    if (options.batch) return const BatchPresenter().call;
    return buildInteractivePresenter();
  }
}
