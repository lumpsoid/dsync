import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/models/plan.dart';
import 'package:dsync/dsync_core/models/scan_entry.dart';

import 'non_interactive_stdin_error.dart';

/// The legend printed once, before the first prompt, so nobody has to guess
/// a key (task d765ef: "the prompt must print its own legend").
const _legend =
    'Interactive review (SPEC §11.3) — one line of input per prompt:\n'
    '  y = accept        s = skip\n'
    '  a = accept all remaining (conflicts left unresolved, not resolved)\n'
    '  q = quit (stop asking; anything not yet decided is left out)\n'
    'A conflict with both sides present offers a direction instead of y:\n'
    '  1 = keep A (copy A -> B)   2 = keep B (copy B -> A)';

/// The default, interactive [Presenter] (SPEC §11.3): shows each conflict,
/// then each proposed action, and asks the user to accept, skip, pick a
/// direction, or accept every remaining item without asking.
///
/// Reads and writes are constructor-injected — [lines] (one answer per
/// element), [output], and [isTerminal] — rather than touching `stdin`/
/// `stdout` directly, so this is testable with scripted input and no
/// terminal at all (task d765ef). [isTerminal] is a plain `bool` the caller
/// determines however it likes (typically `stdin.hasTerminal`); this class
/// never inspects the real `stdin`.
///
/// A resolved conflict becomes a new [PlanAction] on the returned list; a
/// skipped item, or a conflict never reached because the user chose "accept
/// all remaining" or "quit" first, is simply left off it — `RunController`'s
/// [Presenter] typedef is shaped so that is all a caller ever needs (see its
/// doc comment). No accept/skip wrapper type is introduced here.
///
/// "Accept all remaining" never resolves a conflict, only ever remaining
/// plain actions: SPEC §6 says conflicts are never auto-resolved, and a bulk
/// "yes to everything" has no way to ask which direction an unreviewed
/// conflict should go. So once chosen, any conflict not yet reviewed is left
/// unresolved (as if skipped) and every remaining action is accepted as-is.
/// "Quit" is more conservative still: it stops immediately and leaves
/// everything not yet decided — conflicts and actions alike — out of the
/// result.
class InteractivePresenter {
  final Stream<String> lines;
  final IOSink output;
  final bool isTerminal;

  InteractivePresenter({
    required this.lines,
    required this.output,
    required this.isTerminal,
  });

  /// Keys valid for a one-sided [Conflict] or a plain action: there is only
  /// one possible outcome to accept, so no direction pick is offered
  /// (task d765ef: "handle it rather than offering an impossible choice").
  static const _acceptSkipKeys = {'y', 's', 'a', 'q'};

  /// Keys valid for a [Conflict] with both sides present.
  static const _directionKeys = {'1', '2', 's', 'a', 'q'};

  Future<List<PlanAction>> call(Plan plan) async {
    if (!isTerminal) throw const NonInteractiveStdinError();
    if (plan.conflicts.isEmpty && plan.actions.isEmpty) return const [];

    output.writeln(_legend);
    final resolved = <PlanAction>[];
    final input = StreamIterator<String>(lines);
    try {
      var acceptAllRemaining = false;

      for (final conflict in plan.conflicts) {
        // SPEC §6: a conflict is never auto-resolved, so "accept all
        // remaining" leaves every conflict it did not personally review
        // unresolved rather than picking a direction for it.
        if (acceptAllRemaining) break;

        final key = await _promptConflict(conflict, input);
        switch (key) {
          case 'q':
            return resolved;
          case 'a':
            acceptAllRemaining = true;
            break;
          case 's':
            break;
          default:
            resolved.add(_conflictAction(conflict, key));
            break;
        }
      }

      for (final action in plan.actions) {
        if (acceptAllRemaining) {
          resolved.add(action);
          continue;
        }

        final key = await _promptAction(action, input);
        switch (key) {
          case 'q':
            return resolved;
          case 'a':
            acceptAllRemaining = true;
            resolved.add(action);
            break;
          case 's':
            break;
          default: // 'y'
            resolved.add(action);
            break;
        }
      }
    } finally {
      await input.cancel();
    }
    return resolved;
  }

  Future<String> _promptConflict(
    Conflict conflict,
    StreamIterator<String> input,
  ) async {
    output.writeln('--- conflict: ${conflict.path}');
    output.writeln('  A: ${_describeSide(conflict.onA)}');
    output.writeln('  B: ${_describeSide(conflict.onB)}');

    if (conflict.onA == null || conflict.onB == null) {
      final onlyDirection = conflict.onA == null ? 'B -> A' : 'A -> B';
      output.write(
        '  [y] accept (copy $onlyDirection)  [s] skip  '
        '[a] accept all remaining  [q] quit > ',
      );
      return _read(input, _acceptSkipKeys);
    }

    output.write(
      '  [1] keep A (copy A -> B)  [2] keep B (copy B -> A)  [s] skip  '
      '[a] accept all remaining  [q] quit > ',
    );
    return _read(input, _directionKeys);
  }

  Future<String> _promptAction(
    PlanAction action,
    StreamIterator<String> input,
  ) async {
    output.writeln('--- ${_describeActionType(action.type)}: ${action.path}');
    output.write(
      '  [y] accept  [s] skip  [a] accept all remaining  [q] quit > ',
    );
    return _read(input, _acceptSkipKeys);
  }

  /// Reads one line, re-prompting on anything not in [validKeys]. A closed
  /// input stream is treated as an implicit quit — with nothing left to
  /// read, quitting is the only answer that does not silently accept or
  /// resolve anything on the user's behalf.
  Future<String> _read(
    StreamIterator<String> input,
    Set<String> validKeys,
  ) async {
    while (true) {
      if (!await input.moveNext()) return 'q';
      final raw = input.current;
      final key = raw.trim().toLowerCase();
      if (validKeys.contains(key)) return key;
      output.writeln(
        'Not understood: "$raw". Enter one of: ${validKeys.join('/')}.',
      );
    }
  }

  /// Builds the [PlanAction] for a conflict resolved with [key] — a
  /// direction pick ('1'/'2') on a two-sided conflict, or the one possible
  /// direction ('y') on a one-sided one. [bytes] is the chosen source
  /// side's size (SPEC §6: the copy moves that side's content), falling
  /// back to zero when the source has none recorded.
  PlanAction _conflictAction(Conflict conflict, String key) {
    final copyAtoB = conflict.onB == null || key == '1';
    final type = copyAtoB ? ActionType.copyAtoB : ActionType.copyBtoA;
    final bytes = (copyAtoB ? conflict.onA : conflict.onB)?.size ?? 0;
    return PlanAction(path: conflict.path, type: type, bytes: bytes);
  }

  String _describeSide(ScanEntry? entry) {
    if (entry == null) return '(absent)';
    final size = entry.size == null ? '' : ', ${entry.size} bytes';
    final hash = entry.hash == null ? '' : ', hash ${entry.hash}';
    return '${entry.status.name}$size$hash';
  }

  String _describeActionType(ActionType type) => switch (type) {
    ActionType.copyAtoB => 'copy A -> B',
    ActionType.copyBtoA => 'copy B -> A',
    ActionType.deleteOnA => 'delete on A',
    ActionType.deleteOnB => 'delete on B',
    ActionType.commitOnly => 'commit only (same content)',
  };
}
