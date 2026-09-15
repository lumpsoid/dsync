import 'dart:io';

import 'package:dsync/cli/options/verbosity.dart';
import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/run_event.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';
import 'package:dsync/dsync_core/models/scan_result.dart';
import 'package:dsync/dsync_core/models/skipped_path.dart';

/// Run-level facts about one replica side, known before the run starts —
/// resolved by whatever already computes them (`resolveArchiveLogPath`,
/// `resolveLockPath`, `sshArgsFor`, `Location.classify`), never by this
/// renderer, which touches no filesystem and spawns nothing so it stays
/// testable on plain values.
///
/// One object per side rather than five loose parameters per side on
/// [HumanRenderer]'s constructor: values that must stay matched up with
/// each other (this archive path goes with this lock path goes with this
/// ssh argv goes with this location, for side A and not side B) is exactly
/// the kind of cluster CLAUDE.md says to give a name to, so a wiring mistake
/// pairing A's archive path with B's location cannot even be expressed.
///
/// [location] and [locality] were added for SPEC §11.4's run header (task
/// ee190c) — the same "known before the run starts" facts [archivePath] and
/// [lockPath] already are, just not previously retained anywhere.
class ReplicaDiagnostics {
  final String archivePath;
  final String lockPath;

  /// This side's location exactly as [EffectiveOptions] resolved it into
  /// side A or B (no `~`/env-var expansion, no canonicalization): the run
  /// header shows back what was typed, unmodified, so a mistyped location
  /// reads as the mistake it is rather than something already normalized.
  final Location location;

  /// Where this side's agent actually runs (SPEC §4.1) — decided once by
  /// whoever resolved this side ([resolveReplicaAgents]) and handed down
  /// here rather than re-derived from [sshArgs]: a side's locality is a fact
  /// about it, not something to infer from a diagnostic that happens to
  /// correlate with it.
  final Locality locality;

  /// The ssh argv used to reach this side (`sshArgsFor`), or `null` when the
  /// side is local. `null` rather than an empty list: an empty list would
  /// claim a remote side was reached with zero arguments, which
  /// `sshArgsFor` never produces — the absence itself is what says "local".
  final List<String>? sshArgs;

  const ReplicaDiagnostics({
    required this.archivePath,
    required this.lockPath,
    required this.location,
    required this.locality,
    this.sshArgs,
  });
}

/// Renders one `RunController` run as human-readable text (SPEC §11.4),
/// [render]ed one [RunEvent] at a time as the stream arrives.
///
/// A renderer over plain [RunEvent] values, not over `RunController` or a
/// `Stream` — it never reaches for `stdout`/`stderr` itself, so it tests with
/// a buffer and no TTY. [out] and [err] are constructor parameters for the
/// same reason a real run passes real console sinks and a test passes an
/// in-memory one.
///
/// [verbosity] picks how much of SPEC §11.4's three levels this instance
/// shows (task e9b4b6, DECIDED):
/// - [Verbosity.quiet] — the summary line and any error. Nothing else.
/// - [Verbosity.normal] — run header (via [_renderReplicas], below), plan
///   table, conflicts, skipped-path notes, progress, summary.
/// - [Verbosity.verbose] — everything [Verbosity.normal] shows, plus (via
///   [renderPreamble]) the effective ignore/follow rules and each side's
///   resolved archive/lock paths and ssh argv, (per-path, on
///   [_renderConflict]) the fourth DECIDED item — the reason behind each
///   status, which of SPEC §5.2's branches decided it (task 8a3ff1's
///   [ScanEntry.reason]) — and (on [_renderScanTally], task 1fd42b) the
///   per-side scan fast-path tally: how many paths never needed a rehash
///   versus how many did but turned out unchanged anyway, the one reason
///   pair no other event ever reports (see [RunScanTallyEvent]'s own doc
///   comment). [_renderConflict] is the one per-path line that already shows
///   a raw [ScanStatus] at all — plan and result lines show [ActionType]
///   instead, which the reason never changes (see [ScanReason]'s doc comment
///   and `PlanAction`'s), so there is nothing for it to add there.
///
/// SPEC §11.4's run header — "which replicas, and when this pair last
/// synced" (task ee190c) — is [render]ed like any other event, from a
/// [RunReplicasEvent]: `RunController.run()` yields exactly one, right after
/// both sides' `hello()` succeed and before locking begins, so this is
/// always the first thing a successful run's stream produces. It is a
/// [render] case rather than a call made once up front (the way
/// [renderPreamble] is, before the stream starts) because the one thing it
/// needs beyond [profileId]/[isAdHoc]/[diagnosticsA]/[diagnosticsB] — each
/// side's `hello` reply — genuinely does not exist until `RunController`
/// produces it.
class HumanRenderer {
  final IOSink out;
  final IOSink err;
  final Verbosity verbosity;

  /// SPEC §10's `warn_size_bytes`, already resolved from profile/flag by the
  /// caller. `null` means no warning was configured — SPEC §10 calls it
  /// optional, so "never warn" must be representable without a sentinel.
  final int? warnSizeBytes;

  /// The run's effective ignore/follow rules (SPEC §9) — profile and
  /// `--ignore` flags already merged, the same [RuleSet] the caller hands to
  /// `RunController`. Shown at [Verbosity.verbose] only, via
  /// [renderPreamble].
  final RuleSet? rules;

  /// Replica A's and B's [ReplicaDiagnostics] — each side's location,
  /// locality, archive path, and lock path. Shown at [Verbosity.verbose] via
  /// [renderPreamble] (archive/lock paths and ssh argv), and at
  /// [Verbosity.normal] via the run header (location and locality).
  /// Independently nullable: a caller with diagnostics for one side but not
  /// the other (or neither) still gets a working renderer that shows
  /// whatever it has.
  final ReplicaDiagnostics? diagnosticsA;
  final ReplicaDiagnostics? diagnosticsB;

  /// This run's profile id (SPEC §8.1, §8.3) — a profile's name, or the
  /// derived `adhoc-<16 hex>` (SPEC ee190c's DECIDED, `EffectiveOptions`'s
  /// own doc comment). Shown in the run header.
  final String profileId;

  /// Whether this run has no profile — `sync <locA> <locB>` rather than
  /// `sync <profile>` (SPEC §11.1). Decides the run header's shape: a
  /// profile run shows its name once, up top; an ad-hoc run has no name
  /// worth centering there, so [profileId] (the derived id) instead sits
  /// next to the per-pair summary line, which is where showing it actually
  /// matters — "which id did canonicalization derive for this pair" (task
  /// ee190c).
  final bool isAdHoc;

  /// The wall clock, for the run header's "N day(s) ago" (task ee190c) —
  /// threaded through rather than read from `DateTime.now()` directly
  /// (matching this codebase's convention for `environment`,
  /// `localAddressLookup`, ...) so a test can fix "now" instead of racing a
  /// real clock.
  final DateTime Function() now;

  HumanRenderer({
    required this.out,
    required this.err,
    required this.verbosity,
    required this.profileId,
    this.warnSizeBytes,
    this.rules,
    this.diagnosticsA,
    this.diagnosticsB,
    this.isAdHoc = false,
    this.now = DateTime.now,
  });

  /// Run-level context — not tied to any one [RunEvent] — shown once, at
  /// [Verbosity.verbose] only (task e9b4b6 DECIDED). Call once, before
  /// feeding the event stream to [render]: this is context the wiring task
  /// already holds ahead of the run (the merged [RuleSet], each side's
  /// resolved paths and ssh argv), not something derived from an event, so
  /// it does not belong in [render]'s switch — core owns [RunEvent]'s shape,
  /// not this file.
  ///
  /// A no-op below [Verbosity.verbose]. Above it, renders whatever subset of
  /// [rules]/[diagnosticsA]/[diagnosticsB] is actually present rather than
  /// requiring all three — a caller missing one (a test, or a head that
  /// doesn't have it yet) still gets the rest.
  void renderPreamble() {
    if (verbosity != Verbosity.verbose) return;

    final rules = this.rules;
    if (rules != null) {
      out.writeln(
        'rules: ignore=${rules.ignorePatterns} follow=${rules.followPatterns}',
      );
    }

    _renderDiagnostics('A', diagnosticsA);
    _renderDiagnostics('B', diagnosticsB);
  }

  void _renderDiagnostics(String side, ReplicaDiagnostics? diagnostics) {
    if (diagnostics == null) return;

    out.writeln('archive $side: ${diagnostics.archivePath}');
    out.writeln('lock $side: ${diagnostics.lockPath}');

    final sshArgs = diagnostics.sshArgs;
    if (sshArgs != null) {
      out.writeln('ssh $side: ${sshArgs.join(' ')}');
    }
  }

  /// Renders one event according to [verbosity]. Stateless across calls: a
  /// [Plan]'s conflicts arrive as individual [RunConflictEvent]s before the
  /// [RunPlanEvent] itself (`RunController._runLocked`), so "conflicts
  /// first" (SPEC §11.3) falls out of rendering events in arrival order —
  /// nothing here buffers or reorders.
  void render(RunEvent event) {
    switch (event) {
      // Survive --quiet (task e9b4b6 DECIDED): unconditional.
      case RunSummaryEvent e:
        _renderSummary(e);
      case RunErrorEvent e:
        _renderError(e);

      // Everything else is silent at Verbosity.quiet.
      case RunReplicasEvent e:
        if (verbosity != Verbosity.quiet) _renderReplicas(e);
      // Verbose-only (task 1fd42b, unlike the rest of this group): a bare
      // dump of all five ScanReasons per side, most of them usually zero,
      // would be noise at Verbosity.normal — see [_renderScanTally]'s own
      // doc comment.
      case RunScanTallyEvent e:
        if (verbosity == Verbosity.verbose) _renderScanTally(e);
      case RunSkippedPathEvent e:
        if (verbosity != Verbosity.quiet) _renderSkippedPath(e);
      case RunConflictEvent e:
        if (verbosity != Verbosity.quiet) _renderConflict(e);
      case RunPlanEvent e:
        if (verbosity != Verbosity.quiet) _renderPlan(e);
      case RunActionEvent e:
        if (verbosity != Verbosity.quiet) _renderAction(e);
      case RunResultEvent e:
        if (verbosity != Verbosity.quiet) _renderResult(e);
      case RunProgressEvent e:
        if (verbosity != Verbosity.quiet) _renderProgress(e);
    }
  }

  /// SPEC §11.4's run header (task ee190c): which replicas this run
  /// connects, and what the tool already knows about the pair, ahead of the
  /// plan. A profile run shows its name once, up top ([isAdHoc] false); an
  /// ad-hoc run has no name to show there, so [profileId] — the derived id
  /// canonicalization produced — sits on the summary line instead, right
  /// where "first sync of this pair" would otherwise stand alone (task
  /// ee190c: "that is what keeps canonicalization from being a silent
  /// implication").
  ///
  /// "First sync" (SPEC §6, "a path one side has never seen") is flagged
  /// whenever either side's archive has never committed — [event]'s
  /// [ReplicaInfo.lastCommitTime] `null` on either side — and the
  /// asymmetric case (one side has history, the other none) is worded
  /// differently from the both-empty case: the same silent mirroring run
  /// results either way, but only the asymmetric one is likely a mistake
  /// (a wiped state dir) rather than an expected first run.
  void _renderReplicas(RunReplicasEvent event) {
    if (!isAdHoc) out.writeln('profile $profileId');

    _renderReplicaRow('A', diagnosticsA);
    _renderReplicaRow('B', diagnosticsB);

    final lastA = event.infoA.lastCommitTime;
    final lastB = event.infoB.lastCommitTime;
    final label = isAdHoc ? '$profileId · ' : '';

    if (lastA == null && lastB == null) {
      out.writeln('  ${label}first sync of this pair');
      _renderFirstSyncNote();
    } else if (lastA == null || lastB == null) {
      final emptySide = lastA == null ? 'A' : 'B';
      out.writeln(
        '  ${label}first sync of this pair '
        '($emptySide has no archive yet — a wiped state dir, or a new '
        'replica joining an established one)',
      );
      _renderFirstSyncNote();
    } else {
      out.writeln('  $label${_lastSyncedSummary(lastA, lastB)}');
    }
  }

  void _renderReplicaRow(String side, ReplicaDiagnostics? diagnostics) {
    if (diagnostics == null) return;
    final locality = diagnostics.locality == Locality.inProcess
        ? 'local'
        : 'ssh';
    // `Location.toString` spells a location back the way SPEC §2 writes it,
    // unexpanded and uncanonicalized, so a mistyped one reads as the mistake
    // it is — including the `ssh://` prefix that decided this row says `ssh`.
    out.writeln('$side  ${diagnostics.location}  $locality');
  }

  /// One shared "last synced" line when both sides agree to the minute,
  /// otherwise one per side: SPEC §7.3/§8.2 already tolerate the two
  /// archives committing at slightly different instants (a crash between
  /// the two commits resolves on the next run), so nothing guarantees they
  /// land in the same minute.
  String _lastSyncedSummary(DateTime lastA, DateTime lastB) {
    final formattedA = _formatTimestamp(lastA);
    final formattedB = _formatTimestamp(lastB);
    if (formattedA == formattedB) {
      return 'last synced $formattedA (${_relativeTime(lastA)})';
    }
    return 'last synced A $formattedA (${_relativeTime(lastA)}), '
        'B $formattedB (${_relativeTime(lastB)})';
  }

  /// SPEC §6's "a path one side has never seen": with no archive on the
  /// affected side(s), a file present on only one side cannot be told apart
  /// from a file the other side already deleted, so it is always copied,
  /// never deleted.
  void _renderFirstSyncNote() {
    out.writeln(
      '! First sync: with no archive, a file present on one side only is '
      'copied,\n'
      '  never deleted — there is no way yet to tell a new file from a '
      'deleted one.',
    );
  }

  String _formatTimestamp(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _relativeTime(DateTime time) {
    final diff = now().difference(time);
    if (diff.inDays >= 1) return '${diff.inDays} day(s) ago';
    if (diff.inHours >= 1) return '${diff.inHours} hour(s) ago';
    if (diff.inMinutes >= 1) return '${diff.inMinutes} minute(s) ago';
    return 'just now';
  }

  /// SPEC §5.2's scan fast-path tally (SPEC §11.4, task 1fd42b), shown at
  /// [Verbosity.verbose] only. A full breakdown of all five [ScanReason]s
  /// per side would be noise — [ScanReasonTally.modified],
  /// [ScanReasonTally.created], and [ScanReasonTally.deleted] already
  /// surface through the plan and action lines, so repeating them here would
  /// only echo what the user already saw. What does not appear anywhere
  /// else, and what actually answers "why is this sync slow", is how many
  /// paths a side scanned in total and how many of those needed a rehash
  /// only to turn out unchanged — a side stuck doing that on every run is a
  /// side worth investigating (a filesystem that rounds mtimes, most
  /// commonly).
  void _renderScanTally(RunScanTallyEvent event) {
    _renderScanTallyLine('A', event.tallyA);
    _renderScanTallyLine('B', event.tallyB);
  }

  void _renderScanTallyLine(String side, ScanReasonTally tally) {
    out.writeln(
      'scan $side: ${tally.total} path(s) scanned, '
      '${tally.hashMatched} rehashed to confirm unchanged',
    );
  }

  /// SPEC §5.1 and §5: a path the scan reported instead of giving it a
  /// status. [RunSkippedPathEvent.onA] says which replica it was found on.
  ///
  /// One line shape per [SkippedReason], not one shared "skipped" line: they
  /// mean different things to the person reading. A symlink line is the tool
  /// confirming it did what §9's rules said; an unreadable line is a file
  /// that did *not* sync and that the user has to go fix, so it says so
  /// outright rather than leaving them to infer it from the word "skipped".
  /// That is the whole point of reporting it — silence is how someone ends up
  /// believing a file is synced when it never was.
  ///
  /// [SkippedPath.detail] goes on both, because on both it is the part the
  /// reader cannot work out for themselves: "broken link" and "target is a
  /// directory this walk is already inside" need different fixes, and only
  /// the walk ever knew which it hit.
  void _renderSkippedPath(RunSkippedPathEvent event) {
    final side = event.onA ? 'A' : 'B';
    final skipped = event.skipped;
    switch (skipped.reason) {
      case SkippedReason.symlink:
        out.writeln('symlink  $side  ${skipped.path}  (${skipped.detail})');
      case SkippedReason.unreadable:
        out.writeln(
          'unreadable  $side  ${skipped.path}  '
          '(${skipped.detail} — not synced)',
        );
    }
  }

  /// SPEC §6: a path the `Reconciler` could not resolve on its own. Shows
  /// each side's [ScanStatus] always, and — at [Verbosity.verbose] only — the
  /// [ScanReason] behind it (SPEC §11.4, task 8a3ff1): which of SPEC §5.2's
  /// branches decided that status, e.g. the fast path never hashing versus a
  /// rehash confirming the content actually matched despite a metadata
  /// drift. Those two reasons both show as `unchanged` without [_describeSide]
  /// naming the branch, so this is exactly the case the task exists for.
  void _renderConflict(RunConflictEvent event) {
    final conflict = event.conflict;
    out.writeln(
      'conflict  ${conflict.path}  '
      '(A: ${_describeSide(conflict.onA)}, '
      'B: ${_describeSide(conflict.onB)})',
    );
  }

  String _describeSide(ScanEntry? entry) {
    if (entry == null) return 'absent';
    if (verbosity != Verbosity.verbose) return entry.status.name;
    return '${entry.status.name} [${_describeReason(entry.reason)}]';
  }

  /// SPEC §5.2's branches, worded for a human reading a conflict line
  /// ([_describeSide], [Verbosity.verbose] only) — mirrors
  /// [_describeActionType]'s job of translating an enum into the table's own
  /// notation rather than its camelCase name.
  String _describeReason(ScanReason reason) => switch (reason) {
    ScanReason.metadataMatched => 'size/mtime matched archive, not rehashed',
    ScanReason.hashMatched => 'size/mtime drifted, rehash matched archive',
    ScanReason.modified => 'rehash differed from archive',
    ScanReason.created => 'no archive entry',
    ScanReason.deleted => 'archive entry, file absent',
  };

  /// SPEC §11.3/§11.4: the plan table, shown before apply. Conflicts are not
  /// repeated here — they already printed as their own [RunConflictEvent]s,
  /// ahead of this event, and this table would just be echoing them.
  ///
  /// SPEC §10: the size warning lives here too, since [Plan.bytesToTransfer]
  /// is what it is measured against and this is where the plan is shown.
  /// "Nothing is blocked" — the warning is one more line, not a prompt.
  void _renderPlan(RunPlanEvent event) {
    final plan = event.plan;
    out.writeln(
      'plan: ${plan.actions.length} action(s), '
      '${plan.conflicts.length} conflict(s), '
      '${plan.bytesToTransfer} byte(s) to transfer',
    );
    for (final action in plan.actions) {
      out.writeln('  ${_describeActionType(action.type)}  ${action.path}');
    }

    final warnSizeBytes = this.warnSizeBytes;
    if (warnSizeBytes != null && plan.bytesToTransfer > warnSizeBytes) {
      out.writeln(
        'warning: plan will transfer ${plan.bytesToTransfer} byte(s), '
        'over warn_size_bytes ($warnSizeBytes) (SPEC §10)',
      );
    }
  }

  /// SPEC §7/§11.4: announced right before `Applier.apply` runs this action
  /// — the closest thing to a per-action "starting" signal (see
  /// [RunActionEvent]'s doc comment) — so a long copy shows something before
  /// its [RunResultEvent] arrives.
  void _renderAction(RunActionEvent event) {
    out.writeln(
      '> ${_describeActionType(event.action.type)}  ${event.action.path}',
    );
  }

  /// SPEC §7.6: one path's outcome. [RunResultEvent.type] is the only
  /// per-result detail available — same caveat as [_renderConflict]: no
  /// event carries a reason beyond the [ActionType] and, on failure, the
  /// error itself.
  void _renderResult(RunResultEvent event) {
    if (event.succeeded) {
      out.writeln(
        '  applied  ${_describeActionType(event.type)}  '
        '${event.path}',
      );
    } else {
      out.writeln(
        '  failed   ${_describeActionType(event.type)}  '
        '${event.path}: ${event.error}',
      );
    }
  }

  /// SPEC §11.4 progress line. Best-effort per [RunProgressEvent]'s own doc
  /// comment: one line per completed path, not a live in-place counter.
  void _renderProgress(RunProgressEvent event) {
    out.writeln('  [${event.completed}/${event.total}]');
  }

  /// SPEC §11.4 summary — applied / skipped / conflicts / failed /
  /// unreadable — and SPEC §11.5's exit-code inputs, printed as a single line
  /// so a cron job can log one line per run (task e9b4b6 DECIDED, quiet
  /// level). Always shown, regardless of [verbosity].
  ///
  /// `unreadable` is the one count here that carries at [Verbosity.quiet]
  /// what the per-path lines cannot (task 37bf4f): those are silenced, so
  /// without it a quiet run that failed to read half the tree would look
  /// identical to one that read all of it.
  void _renderSummary(RunSummaryEvent event) {
    out.writeln(
      'summary: applied=${event.appliedCount} '
      'skipped=${event.skippedCount} '
      'conflicts=${event.conflictCount} '
      'failed=${event.failedCount} '
      'unreadable=${event.unreadableCount}',
    );
  }

  /// SPEC §11.5 exit 3: a fatal error that ended the run early. Always
  /// shown, regardless of [verbosity], and on [err] rather than [out] — the
  /// one line in this renderer that is genuinely an error rather than
  /// information about a successful run.
  void _renderError(RunErrorEvent event) {
    err.writeln('error: ${event.error}');
  }

  /// SPEC §6's action vocabulary, in the table's own notation (`copy A→B`,
  /// ...) rather than the enum's camelCase names.
  String _describeActionType(ActionType type) => switch (type) {
    ActionType.copyAtoB => 'copy A→B',
    ActionType.copyBtoA => 'copy B→A',
    ActionType.deleteOnA => 'delete on A',
    ActionType.deleteOnB => 'delete on B',
    ActionType.commitOnly => 'commit only',
  };
}
