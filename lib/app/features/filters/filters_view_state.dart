import 'package:flutter/foundation.dart';

/// What the Filters page was opened over: the folder whose contents the
/// rules are chosen against, and the rules the form holds right now.
///
/// Values rather than an id, and this is the one handoff in the head that
/// is: the rules being edited belong to a form that has not been saved —
/// a blank Run setup has no profile yet, and a pre-filled one has unsaved
/// edits — so there is no id that names them. The Filters page is a field
/// editor for the page under it, and it hands back what the field is now.
class FiltersArgs {
  const FiltersArgs({required this.rootPath, required this.ignorePatterns});

  /// The absolute path of the local replica root — the folder the browser
  /// lists and the preview walks.
  final String rootPath;

  /// SPEC §9 `ignore` globs the form holds, in order.
  final List<String> ignorePatterns;
}

/// One rule as the rules list draws it.
class FilterRuleRow {
  const FilterRuleRow({required this.pattern, required this.removes});

  /// The glob, as written — also the key the remove button passes back.
  final String pattern;

  /// What this rule takes out of the sync ("−412 files"), or `null` when
  /// no preview has been counted since this rule was last edited.
  ///
  /// `null` rather than a zero: "this rule removes nothing" is a fact a
  /// user acts on — it is what a typo looks like — and showing it before
  /// anything has been counted would be inventing it.
  final String? removes;
}

/// Why a browser row is or is not in the sync — the three answers the page
/// draws differently, as a sum type rather than a flag beside a nullable
/// pattern.
sealed class FilterEntryStatus {
  const FilterEntryStatus();
}

/// Nothing keeps it out.
final class FilterEntrySyncs extends FilterEntryStatus {
  const FilterEntrySyncs();
}

/// A rule keeps it out. [pattern] is the rule to remove to bring it back —
/// an ancestor folder's rule when the row is under one.
final class FilterEntryExcluded extends FilterEntryStatus {
  const FilterEntryExcluded(this.pattern);

  final String pattern;
}

/// A sync carries nothing here whatever the rules say — a symlink, a
/// device node (SPEC §5.1). [reason] is the whole line to show; there is
/// no rule to offer, because there is no rule in the way.
final class FilterEntryUncarried extends FilterEntryStatus {
  const FilterEntryUncarried(this.reason);

  final String reason;
}

/// One child of the folder being browsed, as the page draws it.
class FilterEntryRow {
  const FilterEntryRow({
    required this.name,
    required this.path,
    required this.isFolder,
    required this.status,
    required this.detail,
  });

  final String name;

  /// Root-relative — what an "exclude this exact path" rule is written as.
  final String path;

  /// Whether tapping the row opens it. Only a folder does; everything else
  /// is a leaf.
  final bool isFolder;

  final FilterEntryStatus status;

  /// The size or count beside the row: a file's size, a folder's counted
  /// totals, or `null` when a folder has not been counted — which is every
  /// folder until a preview runs.
  final String? detail;

  /// What can be done to this row, in the order a menu lists them.
  ///
  /// One list for every place a row offers its actions — the trailing
  /// button today, a context menu on the row later — so the choices and
  /// their wording are decided here once rather than per control.
  List<FilterEntryAction> get actions => switch (status) {
    FilterEntrySyncs() => [
      ExcludeEveryNamed(name),
      ExcludeOnlyThis(path: path, isFolder: isFolder),
    ],
    FilterEntryExcluded(:final pattern) => [IncludeAgain(pattern)],
    // No rule is in the way, so there is none to add or drop.
    FilterEntryUncarried() => const [],
  };
}

/// One thing a listing row offers: a rule it can be turned into, or the
/// rule to drop to bring it back. `FiltersController.runEntryAction`
/// carries it out.
///
/// "Exclude everywhere" and "exclude this one" are separate actions rather
/// than one with a flag because they are genuinely different rules, and
/// the user has to be shown both to choose.
sealed class FilterEntryAction {
  const FilterEntryAction();

  /// The action as a menu item says it.
  String get label;
}

/// Excludes anything named [name], wherever it sits in the tree.
final class ExcludeEveryNamed extends FilterEntryAction {
  const ExcludeEveryNamed(this.name);

  final String name;

  @override
  String get label => "Exclude every '$name'";
}

/// Excludes exactly the row at [path] — and, for a folder, what is under
/// it.
final class ExcludeOnlyThis extends FilterEntryAction {
  const ExcludeOnlyThis({required this.path, required this.isFolder});

  final String path;
  final bool isFolder;

  @override
  String get label => 'Exclude only this ${isFolder ? 'folder' : 'file'}';
}

/// Drops [pattern], the rule keeping the row out.
final class IncludeAgain extends FilterEntryAction {
  const IncludeAgain(this.pattern);

  final String pattern;

  @override
  String get label => 'Include';
}

/// Where the browser is and what it found.
sealed class FiltersFolder {
  const FiltersFolder();
}

/// The listing is in flight.
final class FiltersFolderLoading extends FiltersFolder {
  const FiltersFolderLoading();
}

/// [entries] are the children of the folder at [path] — `''` for the
/// replica root — in the order `listFilterFolder` returned them: folders
/// first, then everything else, by name.
final class FiltersFolderListed extends FiltersFolder {
  const FiltersFolderListed({required this.path, required this.entries});

  /// Root-relative path of the folder being shown; `''` is the root.
  final String path;

  final List<FilterEntryRow> entries;
}

/// The folder could not be listed. [message] is the whole line to show —
/// a folder a file manager has since removed, or one this head has no
/// access to.
final class FiltersFolderFailed extends FiltersFolder {
  const FiltersFolderFailed(this.message);

  final String message;
}

/// Where the counted preview stands.
///
/// Counting is a walk of the whole tree, so it happens when the user asks
/// for it and not on every keystroke — see `FiltersController.runPreview`.
sealed class FiltersPreview {
  const FiltersPreview();
}

/// Nothing counted yet: the page has just opened.
final class FiltersPreviewIdle extends FiltersPreview {
  const FiltersPreviewIdle();
}

/// A walk is in flight.
final class FiltersPreviewRunning extends FiltersPreview {
  const FiltersPreviewRunning();
}

/// A walk finished. Every field is a rendered line.
///
/// [stale] says the rules changed since this was counted, so the numbers
/// are the previous rules'. A flag on the one case rather than a fourth
/// case: staleness has no values of its own — it is these same numbers,
/// marked — and a separate case would duplicate all four of them.
final class FiltersPreviewReady extends FiltersPreview {
  const FiltersPreviewReady({
    required this.syncing,
    required this.excluded,
    required this.unreadable,
    required this.stale,
  });

  /// "2,981 files · 14.2 GB".
  final String syncing;

  /// The same shape for what the rules keep out.
  final String excluded;

  /// The line about folders the walk could not read, or `null` when it
  /// read all of them. Shown because their contents are in neither total.
  final String? unreadable;

  final bool stale;

  FiltersPreviewReady asStale() => FiltersPreviewReady(
    syncing: syncing,
    excluded: excluded,
    unreadable: unreadable,
    stale: true,
  );
}

/// The walk failed — the root went away, or access to it was withdrawn.
final class FiltersPreviewFailed extends FiltersPreview {
  const FiltersPreviewFailed(this.message);

  final String message;
}

/// The rendered values of the Filters page: the rules, the folder being
/// browsed, and the last counted preview.
///
/// Holds only what the page displays, per the view-state role in
/// `app_scope.dart` — every count is already a string, and every verdict
/// is already a case. The [rules] list is the page's *result* as well as
/// its data: the page hands it back when it pops, which is how the Run
/// setup form learns what the field is now.
class FiltersViewState extends ChangeNotifier {
  List<String> _rules = const [];
  Map<String, String?> _ruleCounts = const {};
  String _rootPath = '';
  FiltersFolder _folder = const FiltersFolderLoading();
  FiltersPreview _preview = const FiltersPreviewIdle();
  String? _addError;

  /// The `ignore` globs, in the order they were written.
  List<String> get rules => _rules;

  /// The rules as the list draws them, each with what the last preview
  /// says it removes.
  List<FilterRuleRow> get ruleRows => [
    for (final pattern in _rules)
      FilterRuleRow(pattern: pattern, removes: _ruleCounts[pattern]),
  ];

  /// The absolute path of the folder being filtered — the page's subtitle,
  /// and the thing that says *which files we are working on*.
  String get rootPath => _rootPath;

  FiltersFolder get folder => _folder;

  FiltersPreview get preview => _preview;

  /// Why the pattern just typed was refused, or `null`. `FiltersController`
  /// only.
  String? get addError => _addError;

  /// Records the folder being filtered. `FiltersController` only.
  void recordRootPath(String path) {
    _rootPath = path;
    notifyListeners();
  }

  /// Records the rule list, and marks any counted preview stale: the
  /// numbers on screen were counted against the rules as they were, and
  /// leaving them unmarked would be showing a total for a filter that is
  /// no longer set. The per-rule counts go with them.
  /// `FiltersController` only.
  void recordRules(List<String> rules) {
    _rules = List.unmodifiable(rules);
    _ruleCounts = const {};
    if (_preview case FiltersPreviewReady(stale: false) && final ready) {
      _preview = ready.asStale();
    }
    notifyListeners();
  }

  /// Moves the preview, and — when [ruleCounts] is given — records what
  /// each rule removed. `null` leaves the counts alone, which is what a
  /// walk *starting* wants: wiping them would blank the rule list for as
  /// long as the walk runs, and the counts on it are still the ones that
  /// were last counted. `FiltersController` only.
  void recordPreview(
    FiltersPreview preview, {
    Map<String, String?>? ruleCounts,
  }) {
    _preview = preview;
    if (ruleCounts != null) _ruleCounts = ruleCounts;
    notifyListeners();
  }

  /// Records the browser's location. `FiltersController` only.
  void recordFolder(FiltersFolder folder) {
    _folder = folder;
    notifyListeners();
  }

  /// Records why a typed pattern was refused, or clears it.
  /// `FiltersController` only.
  void recordAddError(String? message) {
    _addError = message;
    notifyListeners();
  }
}
