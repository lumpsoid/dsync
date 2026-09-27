import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core_link/core_link.dart';
import '../../core_link/models/core_failure.dart';
import '../../core_link/models/filter_row.dart';
import '../../pop_on_escape.dart';
import '../../readable_width.dart';
import 'file_choice.dart';
import 'folder_picker.dart';

/// Picks a single file to sync as a file entry (Resolved R4), the way this
/// platform's picker can hand back the file's own path
/// (`FolderPicker.picksFilesNatively`):
///
/// - **On Linux, macOS and Windows**, the platform's file dialog — what a
///   desktop user expects, and it answers with a real path.
/// - **On Android and iOS**, the platform folder chooser for where the file
///   lives, then that folder's own listing — [list] reads it with an
///   **empty** ignore list, since a file entry is named explicitly and a
///   profile's `ignore` rules do not apply to it — to choose a name from, or
///   type one that does not exist there yet ([FileChooserPage]).
///
/// **Never `FilePicker.pickFiles` on a phone.** On Android it hands back a
/// copy of the file under the app's own cache directory (`file_picker`
/// 13.1.0 `FileUtils.kt:741-760`), not the real path — a replica root built
/// from it would sync the copy, not the file the user meant. Going through
/// the folder chooser first, the same one every other root is picked with,
/// and then the core's own folder listing, is the only way to end up with a
/// real path there.
///
/// **A file that does not exist yet** — the entry's other side has it, this
/// one is about to receive it — is the one thing a desktop file dialog
/// cannot choose: it opens files, it does not name them. A save dialog
/// would, but `FilePicker.saveFile` writes the bytes it is given to the
/// chosen path (`file_picker_linux` 2.0.0 and `windows_file_picker` 2.0.0
/// `saveFile`), so choosing an existing file there would empty it. So on
/// desktop naming one is a step of its own ([namesNewFilesApart]): the
/// folder chooser, then a name ([nameNewFile]). On a phone the browser's
/// typed-name bar already is that step.
///
/// Shared by the entry editor (Run setup) and the grant flows (Shared
/// folders, Device detail) — a file's path is picked the same way whether
/// it becomes a replica root or a grant, so this sits beside
/// [FolderPicker] rather than under any one feature.
class FileChooser {
  FileChooser(this.core, {required this.picker});

  final CoreLink core;

  /// The platform's file dialog and folder chooser — the same picker every
  /// other root is picked with.
  final FolderPicker picker;

  /// Opens this platform's first step towards a file: its file dialog, or
  /// the folder chooser for a folder to browse. May throw whatever the
  /// platform channel throws.
  Future<FileChoice> start() async {
    if (picker.picksFilesNatively) {
      final path = await picker.pickFile();
      return path == null ? const FileDismissed() : FileChosen(path);
    }
    final root = await picker.pick();
    return root == null ? const FileDismissed() : FileBrowse(root);
  }

  /// Whether a file that does not exist yet is named in a step of its own
  /// ([nameNewFile]) rather than inside [start]'s flow — see the class doc
  /// comment.
  bool get namesNewFilesApart => picker.picksFilesNatively;

  /// Opens the platform folder chooser for the folder a file lives in, or
  /// will; `null` when the user dismissed it.
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

/// Chooses a file with [chooser], start to finish: the full path of the
/// file, or `null` when the user gave up at any step. Where [chooser]'s
/// first step lands on a folder to browse, [FileChooserPage] is pushed over
/// [context] for the rest. May throw whatever the platform channel throws.
Future<String?> chooseFile(BuildContext context, FileChooser chooser) async {
  switch (await chooser.start()) {
    case FileChosen(:final path):
      return path;
    case FileDismissed():
      return null;
    case FileBrowse(:final root):
      if (!context.mounted) return null;
      return Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => FileChooserPage(chooser: chooser, root: root),
        ),
      );
  }
}

/// Names a file that does not exist yet (see [FileChooser]): the folder
/// chooser for where it will be, then a dialog for its name. The full path,
/// or `null` when the user gave up at either step. May throw whatever the
/// platform channel throws.
Future<String?> nameNewFile(BuildContext context, FileChooser chooser) async {
  final root = await chooser.chooseFolder();
  if (root == null || !context.mounted) return null;
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _NewFileDialog(folder: root),
  );
  return name == null ? null : chooser.join(root, name);
}

/// The name of a file not in [folder] yet. Pops the trimmed name, or
/// nothing when cancelled; a blank name is not taken. Its whole point is
/// typing, so its field takes the focus and Enter is Use.
class _NewFileDialog extends StatefulWidget {
  const _NewFileDialog({required this.folder});

  /// Where the file will be — shown so the user knows what the name is
  /// relative to.
  final String folder;

  @override
  State<_NewFileDialog> createState() => _NewFileDialogState();
}

class _NewFileDialogState extends State<_NewFileDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _use() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New file'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('In ${widget.folder}', overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          TextField(
            key: const Key('new-file-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'File name',
              helperText: 'Created here when the other side sends it.',
            ),
            onSubmitted: (_) => _use(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('new-file-use'),
          onPressed: _use,
          child: const Text('Use'),
        ),
      ],
    );
  }
}

/// Browses [root] with [chooser] and pops the full path of the file the
/// user taps, or types and confirms. A folder row descends; a file row (or
/// anything else the core lists, since only `Folder` rows are worth
/// descending into) is taken as the choice.
///
/// Pushed by [chooseFile] the way Filters is (`run_setup_page.dart`'s
/// `_openFilters`): a detail of whichever page opened it, over a folder
/// already chosen, so it needs nothing from a `Navigator` of its own beyond
/// what pushed it. Reached only where a file is chosen by browsing a
/// folder — the phones; a desktop's file dialog never lands here.
class FileChooserPage extends StatefulWidget {
  const FileChooserPage({super.key, required this.chooser, required this.root});

  final FileChooser chooser;

  /// The folder [FileChooser.start] browsed to — every row and every typed
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
    return PopOnEscape(
      child: Scaffold(
        appBar: AppBar(title: Text(_folder ?? 'Choose a file')),
        body: Column(
          children: [
            Expanded(
              child: switch ((_error, _rows)) {
                (final error?, _) => Center(
                  child: ReadableColumn(
                    width: ReadableWidth.list,
                    child: Text(error),
                  ),
                ),
                (null, null) => const Center(
                  child: CircularProgressIndicator(),
                ),
                (null, final rows?) => ReadableScrollPadding(
                  width: ReadableWidth.list,
                  padding: null,
                  builder: (context, padding) => ListView(
                    padding: padding,
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
                ),
              },
            ),
            const Divider(height: 1),
            ReadableColumn(
              width: ReadableWidth.list,
              child: Padding(
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
            ),
          ],
        ),
      ),
    );
  }
}
