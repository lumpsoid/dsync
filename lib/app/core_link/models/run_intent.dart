import 'action_choice.dart';
import 'conflict_choice.dart';

/// What the user did to a run, sent as it is: the core decides what it
/// means where the run stands, and ignores one it cannot take.
///
/// An answer to a question about a plan — the review's, the guards' —
/// carries the [AnswerIntent.planId] of the view it was given on
/// (`RunReviewing.planId` and the guards'), and the core takes it only
/// while that same plan is asked about: a tap on a plan a resume or the
/// next entry has since replaced lands nowhere.
sealed class RunIntent {
  const RunIntent();
}

/// An answer about the plan [planId] names.
sealed class AnswerIntent extends RunIntent {
  const AnswerIntent({required this.planId});

  final int planId;
}

/// The planned action at [index], under review.
final class ChooseAction extends AnswerIntent {
  const ChooseAction(this.index, this.choice, {required super.planId});

  final int index;
  final ActionChoice choice;
}

/// The conflict at [index], under review.
final class ChooseConflict extends AnswerIntent {
  const ChooseConflict(this.index, this.choice, {required super.planId});

  final int index;
  final ConflictChoice choice;
}

/// Apply the review's choices.
final class ConfirmReview extends AnswerIntent {
  const ConfirmReview({required super.planId});
}

/// "Sync all except conflicts": the plan unchanged, whatever was chosen.
final class AcceptAll extends AnswerIntent {
  const AcceptAll({required super.planId});
}

/// SPEC §10's answer: delete, or apply nothing.
final class AnswerDeletes extends AnswerIntent {
  const AnswerDeletes({required super.planId, required this.proceed});

  final bool proceed;
}

/// SPEC §10's overwrite answer: overwrite, or apply nothing.
final class AnswerOverwrites extends AnswerIntent {
  const AnswerOverwrites({required super.planId, required this.proceed});

  final bool proceed;
}

/// The Stop button.
final class StopRun extends RunIntent {
  const StopRun();
}

/// The app went to the background.
final class PauseRun extends RunIntent {
  const PauseRun();
}

/// The Resume button.
final class ResumeRun extends RunIntent {
  const ResumeRun();
}

/// The app came back to the foreground.
final class ForegroundRun extends RunIntent {
  const ForegroundRun();
}

/// The page left.
final class CloseRun extends RunIntent {
  const CloseRun();
}
