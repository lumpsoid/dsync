import 'package:flutter/material.dart';

import '../../core_link/models/root_kind.dart';
import '../../keyboard_first.dart';
import '../../pop_on_escape.dart';
import '../../readable_width.dart';
import '../../run_request.dart';
import '../filters/filters_page.dart';
import '../filters/filters_view_state.dart';
import 'file_chooser.dart';
import 'run_setup_controller.dart';
import 'run_setup_scope.dart';
import 'run_setup_view_state.dart';

/// The Run setup page: pick the entries a run syncs (SPEC §2, §4.4, §11.2,
/// D10). Widgets only, per the page role in `app_scope.dart`: one section
/// per entry — the chosen folder or file with the button that changes it,
/// a kind toggle, a remote root field — a way to add and remove entries,
/// three whole-form text fields, a switch, two buttons, and switches over
/// the rendered [RunSetupPeer] and [RunSetupOutcome].
///
/// The layout is the decision order, in flat sections with no box drawn
/// around them — the heading groups the fields under it, as the Run page's
/// sections do. The entries come first, at equal weight: none is optional
/// and none is a disclosure. What is optional (the dry-run switch, SPEC
/// §4.4's address hatch) is folded under a single "Options". The two ways
/// out are pinned in an action bar so neither scrolls away, with Start
/// filled and Save a text button beside it; the profile name they both read
/// is a field up in the form, so it belongs to neither button.
///
/// Opened from a [RunSetupSource] — a device (blank form) or a saved
/// profile (pre-filled, editable) — and `RunSetupController.load` reads
/// what it needs, resetting the selection and the dry-run choice to this
/// visit's. The cached scope controller, as the Pair page uses, rather than
/// `create()`: `load` is asynchronous, and a controller disposed by a page
/// that left early would have its view state written to after disposal.
///
/// **One remote-root field per entry.** The text fields are the page's, not
/// the view state's (`RunSetupViewState`'s doc comment); [_RunSetupPageState]
/// keeps a list of [_RemoteRootField]s the same length as
/// `RunSetupController`'s entries, rebuilt whenever that count changes
/// (`load`, adding or removing an entry) and left alone otherwise, so a
/// keystroke in one field never disturbs another's.
///
/// **The keyboard walks the fields in the order they are drawn.** Enter in
/// an entry's remote root moves to the next entry's, then to the profile
/// name; Enter in the profile name — the last field outside the Options
/// fold — or in the address inside it starts the run, as the filled button
/// does. Tab walks every control in reading order. The first remote root
/// takes the focus on arrival where the keyboard comes first
/// ([keyboardFirst]); on a phone nothing does, because the first thing to
/// do is pick a folder, not type. Esc backs out like the arrow
/// ([PopOnEscape]) — there is no unsaved-changes question on the arrow
/// either, so there is none on the key.
///
/// [onStart] is the seam to the Run feature: it fires once with the
/// [RunRequest] the controller built, and the entrypoint wires it to the
/// Run route. [onSaved] is the other way out — the profile was written and
/// no run began, so the entrypoint simply leaves the page. This page holds
/// no `Navigator` of its own.
class RunSetupPage extends StatefulWidget {
  const RunSetupPage({
    super.key,
    required this.source,
    required this.onStart,
    required this.onSaved,
  });

  /// What the form opens over: a device's blank form or a saved profile's
  /// pre-filled one.
  final RunSetupSource source;

  /// Called once when the request is built and the page should leave.
  final void Function(RunRequest request) onStart;

  /// Called once when the profile has been saved and the page should leave
  /// without a run. Carries no profile: the home list reloads its own rows.
  final VoidCallback onSaved;

  @override
  State<RunSetupPage> createState() => _RunSetupPageState();
}

class _RunSetupPageState extends State<RunSetupPage> {
  final RunSetupController _controller = runSetupScope.controller;

  /// One remote-root field per entry — see the class doc comment.
  final List<_RemoteRootField> _remoteRoots = [_RemoteRootField('')];
  final _address = TextEditingController();
  final _profileName = TextEditingController();

  /// Where Enter in the last remote root lands.
  final _profileNameFocus = FocusNode();

  /// Listens for the app coming back from the Settings page the refusal's
  /// snackbar opened — and only then: armed by [_openAccessSettings],
  /// disposed on the first resume and with the page.
  AppLifecycleListener? _backFromSettings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loads what [RunSetupPage.source] names, then applies the pre-fill to
  /// this State's text fields — after `load` completes, so the values are
  /// the profile's and not whatever the last visit left.
  Future<void> _load() async {
    await _controller.load(widget.source);
    if (!mounted) return;
    final prefill = _controller.state.prefill;
    _profileName.text = prefill?.profileName ?? '';
    _syncRemoteRoots(prefill?.remoteRoots ?? const ['']);
  }

  /// Rebuilds [_remoteRoots] so it holds exactly [texts].length fields,
  /// seeded with [texts] — called whenever the entry count changes, never
  /// for a keystroke in one of them.
  void _syncRemoteRoots(List<String> texts) {
    for (final field in _remoteRoots) {
      field.dispose();
    }
    _remoteRoots
      ..clear()
      ..addAll([for (final text in texts) _RemoteRootField(text)]);
  }

  @override
  void dispose() {
    _backFromSettings?.dispose();
    for (final field in _remoteRoots) {
      field.dispose();
    }
    _address.dispose();
    _profileName.dispose();
    _profileNameFocus.dispose();
    super.dispose();
  }

  void _addEntry() {
    _controller.addEntry();
    _remoteRoots.add(_RemoteRootField(''));
  }

  void _removeEntry(int index) {
    if (_remoteRoots.length <= 1) return;
    _controller.removeEntry(index);
    _remoteRoots.removeAt(index).dispose();
  }

  /// A refused folder or file is a snackbar, not a line in the form: it
  /// never became one of the entries, so there is no field it belongs
  /// under. See [_showRefusal] for the way out it offers.
  Future<void> _pickFolder(int index) async {
    await _controller.pickLocalFolder(index);
    if (!mounted) return;
    _showRefusal();
  }

  /// Opens the folder chooser, then the browser over what it returned
  /// (R4), and takes the file the user picked or typed as entry [index]'s
  /// local side.
  Future<void> _pickFile(int index) async {
    final chooser = _controller.fileChooser;
    final String? root;
    try {
      root = await chooser.chooseFolder();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the folder chooser: $error')),
      );
      return;
    }
    if (root == null || !mounted) return;
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => FileChooserPage(chooser: chooser, root: root!),
      ),
    );
    if (path == null || !mounted) return;
    await _controller.setLocalFile(index, path);
    if (!mounted) return;
    _showRefusal();
  }

  /// Raises the last refusal, if there is one. A grantable one carries the
  /// way out as its action — the OS page where access to all files is
  /// granted. A final one has no page to send the user to: its line says
  /// what to do, and a close button dismisses it, since there is no action
  /// that would.
  void _showRefusal() {
    final refusal = _controller.state.folderAccessError;
    if (refusal == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(refusal.message),
        duration: const Duration(seconds: 8),
        action: switch (refusal) {
          RunSetupRefusalGrantable() => SnackBarAction(
            label: 'Settings',
            onPressed: _openAccessSettings,
          ),
          RunSetupRefusalFinal() => null,
        },
        showCloseIcon: refusal is RunSetupRefusalFinal,
      ),
    );
  }

  /// Opens Settings and, when the app comes back, has the controller check
  /// the refused path again: granting access there is the fix the
  /// snackbar offered, so the user is not made to pick it twice.
  Future<void> _openAccessSettings() {
    _backFromSettings?.dispose();
    _backFromSettings = AppLifecycleListener(onResume: _backFromSettingsPage);
    return _controller.openAccessSettings();
  }

  Future<void> _backFromSettingsPage() async {
    _backFromSettings?.dispose();
    _backFromSettings = null;
    final checked = await _controller.recheckAfterSettings();
    if (!checked || !mounted) return;
    _showRefusal();
  }

  List<String> _remoteRootTexts() => [
    for (final field in _remoteRoots) field.text.text,
  ];

  Future<void> _start() async {
    await _controller.start(
      remoteRoots: _remoteRootTexts(),
      address: _address.text,
      profileName: _profileName.text,
    );
    if (!mounted) return;
    if (_controller.state.outcome case RunSetupStarted(:final request)) {
      widget.onStart(request);
    }
  }

  Future<void> _save() async {
    await _controller.save(
      remoteRoots: _remoteRootTexts(),
      address: _address.text,
      profileName: _profileName.text,
    );
    if (!mounted) return;
    if (_controller.state.outcome is RunSetupSaved) widget.onSaved();
  }

  /// The Filters page, over entry 0's folder and the profile's rules —
  /// values, not an id, because a form that has not been saved has no id to
  /// hand over (see `FiltersArgs`). Pushed from here rather than from
  /// `dsync_app.dart`: it is a detail of this form, opened over this form's
  /// in-flight values, and the entrypoint knows about neither.
  ///
  /// Bound to entry 0 rather than offered per entry: the ignore rules are
  /// profile-wide (D1), and a file entry offers no preview at all (D8) — so
  /// one representative folder is enough to see what the rules do.
  ///
  /// The result comes back through `onDone`, which fires however the page
  /// leaves — including the system back gesture — so there is no way out
  /// of it that drops what was chosen.
  Future<void> _openFilters(String rootPath) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => FiltersPage(
        args: FiltersArgs(
          rootPath: rootPath,
          ignorePatterns: _controller.state.ignorePatterns,
        ),
        onDone: _controller.setIgnorePatterns,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return PopOnEscape(
      child: Scaffold(
        appBar: AppBar(
          // The title says what the page is, not what is on it: the form
          // already names the device and every folder, so repeating them in
          // the chrome would only take the room a long device name needs.
          title: ListenableBuilder(
            listenable: _controller.state,
            builder: (context, _) => Text(
              _title(_controller.state),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        body: ListenableBuilder(
          listenable: _controller.state,
          builder: (context, _) => switch (_controller.state.peer) {
            RunSetupPeerLoading() => const Center(
              // Nothing else is on screen in this case, so the label carries
              // the whole announcement.
              child: CircularProgressIndicator(
                semanticsLabel: 'Loading the device',
              ),
            ),
            RunSetupPeerMissing(:final message) => ReadableColumn(
              width: ReadableWidth.form,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
            RunSetupPeerLoaded(:final name) => _RunSetupForm(
              controller: _controller,
              deviceName: name,
              editing: _controller.state.prefill != null,
              remoteRoots: _remoteRoots,
              address: _address,
              profileName: _profileName,
              profileNameFocus: _profileNameFocus,
              onPickFolder: _pickFolder,
              onPickFile: _pickFile,
              onAddEntry: () => setState(_addEntry),
              onRemoveEntry: (index) => setState(() => _removeEntry(index)),
              onOpenFilters: _openFilters,
              onStart: _start,
              onSave: _save,
            ),
          },
        ),
      ),
    );
  }
}

/// What the app bar says. A form opened over a saved profile *is* that
/// profile — the home list navigated into it — so it is titled "Profile",
/// not "Edit …": the page is the profile, and every field on it says which
/// device and which folders. A blank form has no profile yet, so it stays
/// "Run setup".
String _title(RunSetupViewState state) =>
    state.prefill != null ? 'Profile' : 'Run setup';

/// The Filters row's second line: what the rules do, in the language of
/// the outcome rather than of the rules — a count of patterns would be
/// counting the mechanism.
String _filtersSummary(RunSetupViewState state, String? rootPath) {
  if (rootPath == null) return 'Pick a folder first.';
  final rules = state.ignorePatterns.length;
  if (rules == 0) return 'Everything in this folder syncs.';
  return '$rules ${rules == 1 ? 'rule keeps' : 'rules keep'} files out of '
      'the sync.';
}

class _RunSetupForm extends StatelessWidget {
  const _RunSetupForm({
    required this.controller,
    required this.deviceName,
    required this.editing,
    required this.remoteRoots,
    required this.address,
    required this.profileName,
    required this.profileNameFocus,
    required this.onPickFolder,
    required this.onPickFile,
    required this.onAddEntry,
    required this.onRemoveEntry,
    required this.onOpenFilters,
    required this.onStart,
    required this.onSave,
  });

  final RunSetupController controller;
  final String deviceName;

  /// Whether the form was opened over a saved profile. Changes what saving
  /// is called and says — an edit writes back over the one profile — and
  /// nothing else: the fields and the rules are the same either way.
  final bool editing;

  /// One field per entry, in order — [_RunSetupPageState] keeps this in
  /// step with `RunSetupController`'s entries.
  final List<_RemoteRootField> remoteRoots;
  final TextEditingController address;
  final TextEditingController profileName;
  final FocusNode profileNameFocus;
  final void Function(int index) onPickFolder;
  final void Function(int index) onPickFile;
  final VoidCallback onAddEntry;
  final void Function(int index) onRemoveEntry;

  /// Opens the Filters page over the folder that has been chosen. Takes
  /// the path rather than reading it back off the view state, so the row
  /// cannot offer itself before there is a folder to filter.
  final void Function(String rootPath) onOpenFilters;

  final VoidCallback onStart;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final starting = state.outcome is RunSetupStarting;
    final entries = state.entries;
    final first = entries.first;
    final firstFolder = first.kind == RootKind.folder ? first.localRoot : null;
    final autofocus = keyboardFirst(context);
    return Column(
      children: [
        Expanded(
          child: ReadableScrollPadding(
            width: ReadableWidth.form,
            padding: const EdgeInsets.all(16),
            builder: (context, padding) => ListView(
              padding: padding,
              children: [
                if (state.prefill case RunSetupPrefill(
                  lastRunUnfinished: true,
                )) ...[
                  Text(
                    key: const Key('run-setup-last-run-unfinished'),
                    'The last run of this profile did not finish. Starting it '
                    'again sorts out what it left: files it never reached sync '
                    'as usual, and a file it stopped mid-write comes back as a '
                    'conflict marked interrupted.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                // Flat sections, no card: the page is the container. The Run
                // page's own sections read the same way (`_Section` there),
                // and a form whose fields are boxed inside a box inside a
                // disclosure is three frames drawn around two decisions.
                for (final (index, entry) in entries.indexed) ...[
                  _EntrySection(
                    index: index,
                    entry: entry,
                    deviceName: deviceName,
                    remoteRoot: remoteRoots[index],
                    autofocus: autofocus && index == 0,
                    nextField: index + 1 < remoteRoots.length
                        ? remoteRoots[index + 1].focus
                        : profileNameFocus,
                    starting: starting,
                    removable: entries.length > 1,
                    onPickFolder: () => onPickFolder(index),
                    onPickFile: () => onPickFile(index),
                    onSetKind: (kind) => controller.setKind(index, kind),
                    onRemove: () => onRemoveEntry(index),
                    onRemoteRootChanged: controller.remoteRootChanged,
                  ),
                  const SizedBox(height: 24),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('run-setup-add-entry'),
                    onPressed: starting ? null : onAddEntry,
                    icon: const Icon(Icons.add),
                    label: const Text('Add another folder or file'),
                  ),
                ),
                const SizedBox(height: 24),
                // Filtering sits with the entries it filters, not under
                // "Options": what a run leaves out is part of *what* is
                // being synced, and a user who has just pointed at a folder
                // full of caches should meet it here rather than find it
                // folded away. It stays a row leading to its own page —
                // choosing rules means looking at real files, which is a
                // screen, not a field. Bound to entry 0's folder, the profile's
                // one representative (the class doc comment on `_openFilters`
                // says why).
                ListTile(
                  key: const Key('run-setup-filters'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.filter_alt_outlined),
                  title: const Text('Filters'),
                  subtitle: Text(_filtersSummary(state, firstFolder)),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !starting && firstFolder != null,
                  onTap: firstFolder == null
                      ? null
                      : () => onOpenFilters(firstFolder),
                ),
                const SizedBox(height: 24),
                // The name sits with the fields it names, not with the
                // buttons: it is part of what gets saved, and both ways out
                // of the page read it.
                TextField(
                  key: const Key('run-setup-profile-name'),
                  controller: profileName,
                  focusNode: profileNameFocus,
                  enabled: !starting,
                  // The last field outside the fold: Enter is Start.
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onStart(),
                  decoration: InputDecoration(
                    labelText: editing
                        ? 'Profile name'
                        : 'Save as profile (optional)',
                    helperText: editing
                        ? 'Saving updates this profile on the home list.'
                        : 'Name this run and it lands on the home list, ready '
                              'to re-run with no typing.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 16),
                _Disclosure(
                  key: const Key('run-setup-options'),
                  title: 'Options',
                  children: [
                    SwitchListTile(
                      key: const Key('run-setup-dry-run'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Dry run'),
                      subtitle: const Text('Show the plan, apply nothing.'),
                      value: state.dryRun,
                      onChanged: starting ? null : controller.setDryRun,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('run-setup-address'),
                      controller: address,
                      enabled: !starting,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => onStart(),
                      decoration: InputDecoration(
                        labelText: 'Address (optional)',
                        hintText: 'host or host:port',
                        helperText:
                            'Leave empty to use the address $deviceName was '
                            'last reached at.',
                        helperMaxLines: 3,
                        errorText: state.addressError,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _ActionBar(
          outcome: state.outcome,
          starting: starting,
          saveLabel: editing ? 'Save changes' : 'Save profile',
          onSave: onSave,
          onStart: onStart,
        ),
      ],
    );
  }
}

/// One entry's section: which of its two sides is a folder or a file, the
/// value picked for each, and its own validation lines. Keyed for entry 0
/// exactly as the page's single entry always was (`run-setup-local-folder`,
/// `run-setup-pick-folder`, `run-setup-remote-root`); every other entry's
/// keys carry its index, so the first entry's tests need no change.
class _EntrySection extends StatelessWidget {
  const _EntrySection({
    required this.index,
    required this.entry,
    required this.deviceName,
    required this.remoteRoot,
    required this.autofocus,
    required this.nextField,
    required this.starting,
    required this.removable,
    required this.onPickFolder,
    required this.onPickFile,
    required this.onSetKind,
    required this.onRemove,
    required this.onRemoteRootChanged,
  });

  final int index;
  final RunEntryForm entry;
  final String deviceName;
  final _RemoteRootField remoteRoot;

  /// Whether the remote root takes the focus when the form appears — the
  /// first entry's, where the keyboard comes first.
  final bool autofocus;

  /// Where Enter in the remote root moves: the next entry's, or the
  /// profile name after the last.
  final FocusNode nextField;
  final bool starting;

  /// Whether this entry can be removed — never the last one (D1).
  final bool removable;
  final VoidCallback onPickFolder;
  final VoidCallback onPickFile;
  final void Function(RootKind kind) onSetKind;
  final VoidCallback onRemove;
  final void Function(String text) onRemoteRootChanged;

  String get _localKey =>
      index == 0 ? 'run-setup-local-folder' : 'run-setup-local-folder-$index';
  String get _pickKey =>
      index == 0 ? 'run-setup-pick-folder' : 'run-setup-pick-folder-$index';
  String get _remoteKey =>
      index == 0 ? 'run-setup-remote-root' : 'run-setup-remote-root-$index';

  @override
  Widget build(BuildContext context) {
    final isFolder = entry.kind == RootKind.folder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Numbered only past one entry: the common case — one entry — reads
        // exactly as it always has, with no count to draw. Past one, every
        // entry is numbered, the first included, and every one removable.
        if (removable)
          Row(
            children: [
              Expanded(child: _SectionLabel('Entry ${index + 1}')),
              IconButton(
                key: Key('run-setup-remove-entry-$index'),
                icon: const Icon(Icons.close),
                tooltip: 'Remove this entry',
                onPressed: starting ? null : onRemove,
              ),
            ],
          ),
        SegmentedButton<RootKind>(
          key: Key('run-setup-kind-$index'),
          segments: const [
            ButtonSegment(
              value: RootKind.folder,
              label: Text('Folder'),
              icon: Icon(Icons.folder_outlined),
            ),
            ButtonSegment(
              value: RootKind.file,
              label: Text('File'),
              icon: Icon(Icons.insert_drive_file_outlined),
            ),
          ],
          selected: {entry.kind},
          onSelectionChanged: starting
              ? null
              : (selection) => onSetKind(selection.first),
        ),
        const SizedBox(height: 8),
        _SectionLabel('On this device'),
        const SizedBox(height: 8),
        // The chosen path shown as a value, not a control: there is one way
        // to set it — the platform chooser, or the file chooser over it —
        // so there is no list to choose from and nothing to type. The
        // button beside it is that one way, in the open.
        Row(
          children: [
            Expanded(
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: isFolder ? 'Folder' : 'File',
                  errorText: entry.localFolderError,
                ),
                child: Text(
                  key: Key(_localKey),
                  entry.localRoot ??
                      (isFolder ? 'No folder chosen' : 'No file chosen'),
                  overflow: TextOverflow.ellipsis,
                  style: entry.localRoot == null
                      ? TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: Key(_pickKey),
              onPressed: starting
                  ? null
                  : (isFolder ? onPickFolder : onPickFile),
              child: Text(
                entry.localRoot == null
                    ? (isFolder ? 'Pick a folder…' : 'Pick a file…')
                    : 'Change',
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _SectionLabel('On $deviceName'),
        const SizedBox(height: 8),
        TextField(
          key: Key(_remoteKey),
          controller: remoteRoot.text,
          focusNode: remoteRoot.focus,
          autofocus: autofocus,
          enabled: !starting,
          textInputAction: TextInputAction.next,
          // Straight to the next field rather than the next control: the
          // default would land on "Add another folder or file", where the
          // next Enter adds an entry.
          onEditingComplete: nextField.requestFocus,
          onChanged: onRemoteRootChanged,
          decoration: InputDecoration(
            labelText: isFolder ? 'Folder' : 'File',
            hintText: isFolder ? '~/notes' : '~/notes/todo.txt',
            helperText: 'Exactly as granted there with `dsync pair grant`.',
            helperMaxLines: 4,
            errorText: entry.remoteRootError,
          ),
        ),
      ],
    );
  }
}

/// One entry's remote-root field: its text and its place in the Enter
/// chain, made, kept and disposed together so the two cannot drift apart
/// the way two parallel lists could.
class _RemoteRootField {
  _RemoteRootField(String text) : text = TextEditingController(text: text);

  final TextEditingController text;
  final FocusNode focus = FocusNode();

  void dispose() {
    text.dispose();
    focus.dispose();
  }
}

/// The two ways out, pinned under the form so neither scrolls away, with
/// the whole-form refusal above them.
///
/// Start is the page's one filled button and Save is a text button beside
/// it: both exits are always reachable, but only one of them is what the
/// page is for. The name they both read is up in the form, under its own
/// label, rather than sitting next to one of them and looking like that
/// button's field.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.outcome,
    required this.starting,
    required this.saveLabel,
    required this.onSave,
    required this.onStart,
  });

  final RunSetupOutcome outcome;
  final bool starting;
  final String saveLabel;
  final VoidCallback onSave;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        // Held to the form's column, so Save and Start sit under the fields
        // they act on rather than at opposite edges of a wide window.
        child: ReadableColumn(
          width: ReadableWidth.form,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OutcomeLine(outcome),
                Row(
                  children: [
                    TextButton(
                      key: const Key('run-setup-save'),
                      onPressed: starting ? null : onSave,
                      child: Text(saveLabel),
                    ),
                    const Spacer(),
                    FilledButton(
                      key: const Key('run-setup-start'),
                      onPressed: starting ? null : onStart,
                      child: starting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              // The spinner replaces the button's label while
                              // the run is starting, so it has to say what the
                              // button now is.
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                semanticsLabel: 'Starting the run',
                              ),
                            )
                          : const Text('Start'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A section's heading, the same `titleSmall` the Run page's sections use
/// (`_Section` in `run_page.dart`) — the heading is what groups the fields
/// under it, so there is no box around them.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleSmall);
  }
}

/// A secondary path folded away. The control above it is the one the form
/// expects; what is in here only opens when that path does not fit, so it
/// reads as an escape hatch rather than a field of equal weight.
///
/// The errors these rows carry — a rejected new folder name, an unparseable
/// address — can only be provoked from inside an open disclosure, so folding
/// one away never hides a message the user has not seen.
class _Disclosure extends StatelessWidget {
  const _Disclosure({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      title: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      shape: const Border(),
      collapsedShape: const Border(),
      children: children,
    );
  }
}

/// The line above the buttons for the outcome that has one. Started and
/// saved show nothing: the page is leaving.
class _OutcomeLine extends StatelessWidget {
  const _OutcomeLine(this.outcome);

  final RunSetupOutcome outcome;

  @override
  Widget build(BuildContext context) {
    return switch (outcome) {
      RunSetupFailed(:final message) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      RunSetupIdle() ||
      RunSetupStarting() ||
      RunSetupSaved() ||
      RunSetupStarted() => const SizedBox.shrink(),
    };
  }
}
