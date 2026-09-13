/// Thrown by [InteractivePresenter] (see `interactive_presenter.dart`) when
/// asked to present a plan but its `isTerminal` constructor argument is
/// `false` (SPEC §11.3).
///
/// Interactive review reads answers from stdin; a non-interactive stdin has
/// no one behind it to answer. Treating that as "accept everything" would
/// let a run write the user's data based on a decision nobody made — the
/// project's rule is to fail loud instead of silently implying consent, so
/// this is thrown rather than swallowed. The caller should require `--batch`
/// (or `--dry-run`) whenever stdin is not a terminal, and treat this as a
/// SPEC §11.5 fatal error (exit code 3) alongside the run's other
/// bad-argument cases.
class NonInteractiveStdinError implements Exception {
  final String message;

  const NonInteractiveStdinError([
    this.message =
        'stdin is not a terminal, so there is no one to answer an '
        'interactive prompt; rerun with --batch or --dry-run',
  ]);

  @override
  String toString() => message;
}
