import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core_link/core_link.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/filter_row.dart';
import 'folder_picker.dart';

/// Picks a single file to sync as a file entry (Resolved R4): the platform
/// folder chooser for where it lives, then that folder's own listing —
/// [list] reads it with an **empty** ignore list, since a file entry is
/// named explicitly and a profile's `ignore` rules do not apply to it — to
/// choose a name from, or type one that does not exist there yet.
///
/// **Never `FilePicker.pickFiles`.** On Android it hands back a copy of the
/// file under the app's own cache directory (`file_picker` 13.1.0
/// `FileUtils.kt:741-760`), not the real path — a replica root built from it
/// would sync the copy, not the file the user meant. Going through the
/// folder chooser first, the same one every other root is picked with, and
/// then the core's own folder listing, is the only way to end up with a
/// real path on both platforms.
///
/// Shared by the entry editor (Run setup) and the grant flows (Shared
/// folders, Device detail) — a file's path is picked the same way whether
/// it becomes a replica root or a grant, so this sits beside
/// [FolderPicker] rather than under any one feature.
class FileChooser {
  FileChooser(this.core, {required this.picker});

  final CoreLink core;

  /// The platform folder chooser [chooseFolder] opens — the same one every
  /// other root is picked with.
  final FolderPicker picker;

  /// Opens the platform folder chooser for the folder the file lives in;
  /// `null` when the user dismissed it.
  Future<String?> chooseFolder() => picker.pick();

  /// [folder]'s rows under [root] (`null`: the root itself) — [root]'s own
  /// listing, read with no ignore rules so a file entry is never invisibly
  /// filtered by rules that do not apply to it.
  Future<List<FilterRow>> list(String root, String? folder) =>
      core.listFilterFolder(root, folder, const []);

  /// The full local path [root] and a listed row's (or a typed) relative
  /// [path] make together — what an `EntryDraft.localRoot` for a file entry
  /// is sent as.
  String join(String root, String path) => p.join(root, path);
}

/// Browses [root] with [chooser] and pops the full path of the file the
/// user taps, or types and confirms. A folder row descends; a file row (or
/// anything else the core lists, since only `Folder` rows are worth
/// descending into) is taken as the choice.
///
/// Pushed the way Filters and Diagnostics are (`run_setup_page.dart`'s
/// `_openFilters`): a detail of whichever page opened it, over a folder
/// already chosen, so it needs nothing from a `Navigator` of its own beyond
/// what pushed it.
class FileChooserPage extends StatefulWidget {
  const FileChooserPage({super.key, required this.chooser, required this.root});

  final FileChooser chooser;

  /// The folder [chooser.chooseFolder] returned — every row and every typed
  /// name is relative to this.
  final String root;

  @override
  State<FileChooserPage> createState() => _FileChooserPageState();
}

class _FileChooserPageState extends State<FileChooserPage> {
  /// `null`: the root itself.
  String? _folder;
  List<FilterRow>? _rows;
  String? _error;
  final _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _rows = null;
      _error = null;
    });
    final List<FilterRow> rows;
    try {
      rows = await widget.chooser.list(widget.root, _folder);
    } on CoreFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      return;
    }
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  void _open(FilterRow row) {
    if (row.isFolder) {
      setState(() => _folder = row.path);
      _load();
      return;
    }
    Navigator.of(context).pop(widget.chooser.join(widget.root, row.path));
  }

  void _useTyped() {
    final text = _typed.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(widget.chooser.join(widget.root, text));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_folder ?? 'Choose a file')),
      body: Column(
        children: [
          Expanded(
            child: switch ((_error, _rows)) {
              (final error?, _) => Center(child: Text(error)),
              (null, null) => const Center(child: CircularProgressIndicator()),
              (null, final rows?) => ListView(
                children: [
                  for (final row in rows)
                    ListTile(
                      key: Key('file-chooser-row-${row.path}'),
                      leading: Icon(
                        row.isFolder
                            ? Icons.folder_outlined
                            : Icons.insert_drive_file_outlined,
                      ),
                      title: Text(row.name),
                      onTap: () => _open(row),
                    ),
                ],
              ),
            },
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('file-chooser-typed-name'),
                    controller: _typed,
                    decoration: const InputDecoration(
                      labelText: 'Or type a name not listed here yet',
                    ),
                    onSubmitted: (_) => _useTyped(),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const Key('file-chooser-use-typed'),
                  onPressed: _useTyped,
                  child: const Text('Use'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
