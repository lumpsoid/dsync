import 'action_choice.dart';
import 'conflict_choice.dart';

/// What the user did to a run, sent as it is: the core decides what it
/// means where the run stands, and ignores one it cannot take.
sealed class RunIntent {
  const RunIntent();
}

/// The planned action at [index], under review.
final class ChooseAction extends RunIntent {
  const ChooseAction(this.index, this.choice);

  final int index;
  final ActionChoice choice;
}

/// The conflict at [index], under review.
final class ChooseConflict extends RunIntent {
  const ChooseConflict(this.index, this.choice);

  final int index;
  final ConflictChoice choice;
}

/// Apply the review's choices.
final class ConfirmReview extends RunIntent {
  const ConfirmReview();
}

/// "Sync all except conflicts": the plan unchanged, whatever was chosen.
final class AcceptAll extends RunIntent {
  const AcceptAll();
}

/// SPEC §10's answer: delete, or apply nothing.
final class AnswerDeletes extends RunIntent {
  const AnswerDeletes({required this.proceed});

  final bool proceed;
}

/// SPEC §10's overwrite answer: overwrite, or apply nothing.
final class AnswerOverwrites extends RunIntent {
  const AnswerOverwrites({required this.proceed});

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
