import 'profile_draft.dart';

/// What a run syncs.
sealed class RunTarget {
  const RunTarget();
}

final class SavedProfileTarget extends RunTarget {
  const SavedProfileTarget(this.name);

  final String name;
}

/// A one-off pair, saved nowhere.
final class DraftTarget extends RunTarget {
  const DraftTarget(this.draft);

  final ProfileDraft draft;
}
