import 'dart:async';
import 'dart:io';

import 'package:dsync/dsync_core/models/filter_folder_entry.dart';
import 'package:dsync/dsync_core/models/filter_preview_report.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/scan/filter_preview.dart';

import '../../format_bytes.dart';
import 'filters_view_state.dart';

/// Input methods of the Filters page: choosing what a profile leaves out
/// of the sync (SPEC §9).
///
/// **The rules are edited as files, not as globs.** Every input here
/// except [addPattern] names a row the user is looking at —
/// [excludeEverywhere], [excludeExactly], [removeRule] — and the glob is
/// derived from it. A user filtering a phone's storage knows which folder
/// they do not want; asking them to write `**/.thumbnails` first is asking
/// them to learn a pattern language to state something they can already
/// point at. [addPattern] stays for the case pointing cannot express — a
/// suffix across the whole tree — and is where a pattern is compiled and
/// refused if it is malformed, so an invalid rule never reaches the store.
///
/// **Browsing is instant; counting is asked for.** Opening a folder is one
/// listing (`listFilterFolder`) and happens on every tap and after every
/// rule change, because a row's verdict changes with the rules and a stale
/// verdict is a lie about what syncs. The totals need a walk of the whole
/// tree (`previewFilters`), which on a phone's storage is seconds, so they
/// are counted when the user presses Preview and marked stale — never
/// silently recomputed, and never quietly left looking current — when a
/// rule changes under them.
///
/// **No store, no navigation.** This controller reads the filesystem and
/// nothing else: the rules it edits belong to the Run setup form that
/// opened this page, which is what saves them onto the profile. That is
/// also why [FiltersViewState.rules] is the page's result — the page hands
/// the list back as it pops.
class FiltersController {
  /// The view state this controller renders into; owned here, disposed
  /// here.
  final FiltersViewState state = FiltersViewState();

  String _rootPath = '';
  String _folderPath = '';

  /// The last walk's report, kept so a folder row can show how much is
  /// under it. Not the summary — that is already rendered on the view
  /// state — and not cleared when a rule changes, because the counts read
  /// off it are the tree's own and do not move when the rules do.
  FilterPreviewReport? _report;

  /// Bumped by every listing and every walk, so a result that arrives
  /// after the user has moved on — opened another folder, changed a rule,
  /// pressed Preview again — is dropped instead of overwriting what is on
  /// screen. Cheaper and simpler than cancellation, and the only thing
  /// cancellation would buy here is the tail of a walk nobody reads.
  int _generation = 0;

  /// Set by [dispose]. A listing or a walk that lands after the page is
  /// gone writes nothing: both are real filesystem work that the page has
  /// no way to call back, and the view state they would write to is no
  /// longer there to notify.
  bool _disposed = false;

  /// Opens the page over [args]: the folder to browse and the rules the
  /// form currently holds. Starts a visit — nothing is carried over from
  /// the last one, and no preview is counted until it is asked for.
  Future<void> open(FiltersArgs args) async {
    _rootPath = args.rootPath;
    _folderPath = '';
    _report = null;
    state.recordRootPath(args.rootPath);
    state.recordAddError(null);
    state.recordPreview(const FiltersPreviewIdle(), ruleCounts: const {});
    state.recordRules(args.ignorePatterns);
    await _list('');
  }

  /// Opens [relativePath] — `''` for the replica root — in the browser.
  Future<void> openFolder(String relativePath) => _list(relativePath);

  /// Adds a rule that excludes anything named [name], wherever it sits in
  /// the tree — `**/name`, the rule someone means by "I never want
  /// `.thumbnails` folders".
  ///
  /// Refused, with a line on [FiltersViewState.addError], when the name
  /// holds a character SPEC §9's globs read as a wildcard: the grammar has
  /// no escape, so there is no pattern that means this exact name, and a
  /// rule that silently matched more than the row the user tapped would be
  /// worse than none.
  void excludeEverywhere(String name) {
    if (_wildcardRefusal(name, 'name') case final refusal?) {
      state.recordAddError(refusal);
      return;
    }
    _addRule('**/$name');
  }

  /// Adds a rule that excludes exactly [rootRelativePath] and, when it is
  /// a folder, everything under it — the rule for "this one, here, not the
  /// others with the same name". Refused like [excludeEverywhere] when the
  /// path holds a wildcard character.
  void excludeExactly(String rootRelativePath) {
    if (_wildcardRefusal(rootRelativePath, 'path') case final refusal?) {
      state.recordAddError(refusal);
      return;
    }
    _addRule(rootRelativePath);
  }

  /// Adds [pattern] as written — the advanced entry, for a rule no row can
  /// be pointed at. Compiled here: a malformed glob is refused with the
  /// [FormatException]'s own message and never becomes a rule.
  void addPattern(String pattern) {
    final trimmed = pattern.trim();
    if (trimmed.isEmpty) {
      state.recordAddError(_patternRequired);
      return;
    }
    try {
      RuleSet(ignore: [trimmed]);
    } on FormatException catch (e) {
      state.recordAddError(e.message);
      return;
    }
    _addRule(trimmed);
  }

  /// Drops [pattern] from the rules. Everything it was keeping out is back
  /// in the sync, which the browser shows on the re-listing this triggers.
  void removeRule(String pattern) {
    if (!state.rules.contains(pattern)) return;
    state.recordRules([
      for (final rule in state.rules)
        if (rule != pattern) rule,
    ]);
    _relist();
  }

  /// Counts what the current rules keep and drop, by walking the whole
  /// root — what the Preview button asks for. See the class doc comment
  /// for why this is not automatic.
  Future<void> runPreview() async {
    final generation = ++_generation;
    state.recordPreview(const FiltersPreviewRunning());

    final FilterPreviewReport report;
    try {
      report = await previewFilters(rootPath: _rootPath, rules: _ruleSet());
    } on FileSystemException catch (e) {
      if (!_current(generation)) return;
      state.recordPreview(
        FiltersPreviewFailed('Could not read $_rootPath: ${e.message}'),
        ruleCounts: const {},
      );
      return;
    }
    if (!_current(generation)) return;

    _report = report;
    state.recordPreview(
      FiltersPreviewReady(
        syncing: _amount(report.includedFiles, report.includedBytes),
        excluded: _amount(report.excludedFiles, report.excludedBytes),
        unreadable: _unreadableLine(report.unreadableFolders),
        stale: false,
      ),
      ruleCounts: {
        for (final entry in report.excludedFilesByPattern.entries)
          entry.key: entry.value == 0
              ? _removesNothing
              : '−${_files(entry.value)}',
      },
    );
    // The listing on screen was drawn before there were counts to put on
    // its folder rows; re-reading it is one listing and is what makes the
    // numbers appear where the user is looking, not only in the summary.
    _relist();
  }

  /// Re-lists the folder on screen. Called after every rule change: a row
  /// says whether it syncs, and that answer is the rules' — leaving the
  /// listing as it was would leave the folder the user just excluded
  /// looking included.
  void _relist() => unawaited(_list(_folderPath));

  void dispose() {
    _disposed = true;
    state.dispose();
  }

  /// Whether a result that has just arrived is still the one on screen —
  /// the same generation that started it, and a page that is still here.
  bool _current(int generation) => !_disposed && generation == _generation;

  /// Adds [pattern] unless it is already a rule, and re-lists.
  void _addRule(String pattern) {
    state.recordAddError(null);
    if (state.rules.contains(pattern)) return;
    state.recordRules([...state.rules, pattern]);
    _relist();
  }

  Future<void> _list(String relativePath) async {
    if (_disposed) return;
    final generation = ++_generation;
    _folderPath = relativePath;
    state.recordFolder(const FiltersFolderLoading());

    final List<FilterFolderEntry> entries;
    try {
      entries = await listFilterFolder(
        rootPath: _rootPath,
        relativePath: relativePath,
        rules: _ruleSet(),
      );
    } on FileSystemException catch (e) {
      if (!_current(generation)) return;
      state.recordFolder(FiltersFolderFailed('Could not open: ${e.message}'));
      return;
    }
    if (!_current(generation)) return;

    state.recordFolder(
      FiltersFolderListed(
        path: relativePath,
        entries: [for (final entry in entries) _rowFor(entry)],
      ),
    );
  }

  /// One listed child as a row. A folder's [FilterEntryRow.detail] is
  /// everything under it — files that sync *and* files a rule keeps out —
  /// because that number is a fact about the tree rather than about the
  /// rules, so it stays true while a preview goes stale. Whether any of it
  /// syncs is [FilterEntryRow.status]'s answer, right beside it.
  FilterEntryRow _rowFor(FilterFolderEntry entry) {
    final folder = entry.kind == FilterEntryKind.folder
        ? _countedFolder(entry.path)
        : null;
    return FilterEntryRow(
      name: entry.name,
      path: entry.path,
      isFolder: entry.kind == FilterEntryKind.folder,
      status: switch (entry) {
        FilterFolderEntry(kind: FilterEntryKind.other) =>
          const FilterEntryUncarried(_uncarried),
        FilterFolderEntry(excludedBy: final pattern?) => FilterEntryExcluded(
          pattern,
        ),
        _ => const FilterEntrySyncs(),
      },
      detail: switch (entry.kind) {
        FilterEntryKind.file => formatBytes(entry.sizeBytes ?? 0),
        FilterEntryKind.folder =>
          folder == null
              ? null
              : _amount(
                  folder.includedFiles + folder.excludedFiles,
                  folder.includedBytes + folder.excludedBytes,
                ),
        FilterEntryKind.other => null,
      },
    );
  }

  /// The walked node for [relativePath], or `null` when no walk has
  /// covered it — before the first preview, or for a folder created since.
  FilterPreviewFolder? _countedFolder(String relativePath) =>
      _report?.folderAt(relativePath);

  RuleSet _ruleSet() => RuleSet(ignore: state.rules);

  /// The refusal for a [what] ("name", "path") SPEC §9 cannot match
  /// literally, or `null` when it can.
  String? _wildcardRefusal(String value, String what) {
    for (final character in _globWildcards) {
      if (value.contains(character)) {
        return 'This $what contains `$character`, which a rule reads as a '
            'wildcard — and rules have no way to spell it literally. Use '
            'Add rule to write a pattern that matches it on purpose.';
      }
    }
    return null;
  }
}

/// "2,981 files · 14.2 GiB", or "1 file · 3.4 KiB".
String _amount(int files, int bytes) =>
    '${_files(files)} · ${formatBytes(bytes)}';

/// "2,981 files", grouped in threes — `intl` is not a dependency (see
/// `format_bytes.dart`), and a six-figure file count read without
/// separators is a number nobody can take in at a glance.
String _files(int count) {
  final digits = count.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '$buffer ${count == 1 ? 'file' : 'files'}';
}

/// The line about folders the walk could not read, or `null`.
String? _unreadableLine(List<String> folders) {
  if (folders.isEmpty) return null;
  final count = folders.length;
  return '$count ${count == 1 ? 'folder' : 'folders'} could not be read, so '
      'nothing under ${count == 1 ? 'it' : 'them'} is in these totals.';
}

/// Characters SPEC §9's glob grammar reads as pattern syntax. It has no
/// escape, so a name holding one of these cannot be matched literally.
const _globWildcards = ['*', '?', '['];

const _patternRequired = 'Type a pattern, such as **/*.tmp.';
const _removesNothing = 'removes nothing';
const _uncarried = 'Not carried by a sync — a link, not a file.';
