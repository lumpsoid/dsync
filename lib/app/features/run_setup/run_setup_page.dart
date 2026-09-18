import 'package:flutter/material.dart';

import '../../run_request.dart';
import 'run_setup_controller.dart';
import 'run_setup_scope.dart';
import 'run_setup_view_state.dart';
import 'scan_cost_sheet.dart';

/// The Run setup page: pick the two locations a run syncs (SPEC §2, §4.4,
/// §11.2). Widgets only, per the page role in `app_scope.dart`: a folder
/// picker, four text fields, a switch, one button, and switches over the
/// rendered [RunSetupPeer] and [RunSetupOutcome].
///
/// Opened from a [RunSetupSource] — a device (blank form) or a saved
/// profile (pre-filled, editable) — and `RunSetupController.load` reads
/// what it needs, resetting the selection and the dry-run choice to this
/// visit's. The cached scope controller, as the Pair page uses, rather than
/// `create()`: `load` is asynchronous, and a controller disposed by a page
/// that left early would have its view state written to after disposal.
///
/// The pre-fill lands in this `State`'s own `TextEditingController`s, read
/// once from the view state after `load` completes — the text fields are
/// the page's, not the view state's (`RunSetupViewState`'s doc comment).
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
  final _newFolder = TextEditingController();
  final _remoteRoot = TextEditingController();
  final _address = TextEditingController();
  final _profileName = TextEditingController();

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
    if (prefill != null) {
      _profileName.text = prefill.profileName;
      _remoteRoot.text = prefill.remoteRoot;
    }
  }

  @override
  void dispose() {
    _newFolder.dispose();
    _remoteRoot.dispose();
    _address.dispose();
    _profileName.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    await _controller.createLocalFolder(_newFolder.text);
    if (!mounted) return;
    if (_controller.state.newFolderError == null) _newFolder.clear();
  }

  /// A refused folder is a snackbar, not a line in the form: it never became
  /// one of the choices, so there is no field it belongs under. The action
  /// is the way out — the OS page where access to all files is granted.
  Future<void> _pickFolder() async {
    await _controller.pickLocalFolder();
    if (!mounted) return;
    final refusal = _controller.state.folderAccessError;
    if (refusal == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(refusal),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: _controller.openAccessSettings,
        ),
      ),
    );
  }

  /// Measures where a scan of the selected folder goes (task 1a341e), then
  /// opens the report.
  ///
  /// The sheet opens from here rather than from the controller for the reason
  /// every other navigation on this page does: the controller records an
  /// outcome and the page decides what to show for it. A measurement that
  /// failed is a snackbar — it is about a folder, not about a field, the same
  /// call `_pickFolder` makes for a refused pick.
  Future<void> _measureScanCost() async {
    await _controller.measureScanCost();
    if (!mounted) return;
    switch (_controller.state.scanCost) {
      case ScanCostMeasured(:final report):
        await showScanCost(context, report);
      case ScanCostFailed(:final message):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      case ScanCostIdle() || ScanCostMeasuring():
        break;
    }
  }

  Future<void> _start() async {
    await _controller.start(
      remoteRoot: _remoteRoot.text,
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
      remoteRoot: _remoteRoot.text,
      address: _address.text,
      profileName: _profileName.text,
    );
    if (!mounted) return;
    if (_controller.state.outcome is RunSetupSaved) widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Run setup')),
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
          RunSetupPeerMissing(:final message) => Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          RunSetupPeerLoaded(:final name) => _RunSetupForm(
            controller: _controller,
            deviceName: name,
            newFolder: _newFolder,
            remoteRoot: _remoteRoot,
            address: _address,
            profileName: _profileName,
            onCreateFolder: _createFolder,
            onPickFolder: _pickFolder,
            onMeasureScanCost: _measureScanCost,
            onStart: _start,
            onSave: _save,
          ),
        },
      ),
    );
  }
}

class _RunSetupForm extends StatelessWidget {
  const _RunSetupForm({
    required this.controller,
    required this.deviceName,
    required this.newFolder,
    required this.remoteRoot,
    required this.address,
    required this.profileName,
    required this.onCreateFolder,
    required this.onPickFolder,
    required this.onMeasureScanCost,
    required this.onStart,
    required this.onSave,
  });

  final RunSetupController controller;
  final String deviceName;
  final TextEditingController newFolder;
  final TextEditingController remoteRoot;
  final TextEditingController address;
  final TextEditingController profileName;
  final VoidCallback onCreateFolder;
  final VoidCallback onPickFolder;
  final VoidCallback onMeasureScanCost;
  final VoidCallback onStart;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final starting = state.outcome is RunSetupStarting;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Sync with $deviceName',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        _SectionLabel('On this device'),
        const SizedBox(height: 8),
        // One card, so the folder reads as a single decision: the dropdown
        // is the choice, and the two ways of adding a folder to it are a
        // disclosure under it rather than controls competing with it.
        Card.outlined(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A plain `DropdownButton` under an `InputDecorator` rather
                // than a `DropdownButtonFormField`: the form field keeps its
                // own copy of the selection and would not follow the
                // controller selecting a folder it just created.
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Folder',
                    helperText:
                        "A folder in this app's documents, or one you pick.",
                    errorText: state.localFolderError,
                  ),
                  child: DropdownButton<String>(
                    key: const Key('run-setup-local-folder'),
                    value: state.selectedLocalFolder,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    hint: const Text('Pick a folder'),
                    items: [
                      for (final folder in state.localFolders)
                        DropdownMenuItem(
                          value: folder.path,
                          child: Text(
                            folder.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: starting ? null : controller.selectLocalFolder,
                  ),
                ),
                _Disclosure(
                  key: const Key('run-setup-folder-options'),
                  title: 'Add another folder',
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('run-setup-pick-folder'),
                        onPressed: starting ? null : onPickFolder,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Pick a folder on this device'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('run-setup-new-folder'),
                            controller: newFolder,
                            enabled: !starting,
                            decoration: InputDecoration(
                              labelText: 'New folder',
                              errorText: state.newFolderError,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          key: const Key('run-setup-create-folder'),
                          onPressed: starting ? null : onCreateFolder,
                          child: const Text('Create'),
                        ),
                      ],
                    ),
                  ],
                ),
                // Under the folder card, because it is about the folder the
                // card selected and about nothing else on this page — and a
                // disclosure, because it is a diagnostic: the answer to "why
                // is this slow" is worth a tap to find and should not sit in
                // the path of someone who only wants to start a run.
                _Disclosure(
                  key: const Key('run-setup-scan-cost'),
                  title: 'Measure scan cost',
                  children: [
                    Text(
                      'Walks this folder several times, adding one step each '
                      'time, to split the scan into what Android costs and '
                      'what dsync adds. Takes minutes on a large folder. '
                      'Nothing is written and no run is started.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: switch (state.scanCost) {
                        // Disabled *and* labelled while it runs: on the tree
                        // sizes this exists for there is nothing else on
                        // screen to say the walk is still going.
                        ScanCostMeasuring() => OutlinedButton.icon(
                          onPressed: null,
                          icon: const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          label: const Text('Measuring…'),
                        ),
                        _ => OutlinedButton.icon(
                          key: const Key('run-setup-measure-scan-cost'),
                          onPressed: starting ? null : onMeasureScanCost,
                          icon: const Icon(Icons.timer_outlined),
                          label: const Text('Measure'),
                        ),
                      },
                    ),
                    if (state.scanCost case ScanCostMeasured(:final report))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const Key('run-setup-show-scan-cost'),
                          onPressed: () => showScanCost(context, report),
                          child: const Text('Show last report'),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _SectionLabel('On $deviceName'),
        const SizedBox(height: 8),
        TextField(
          key: const Key('run-setup-remote-root'),
          controller: remoteRoot,
          enabled: !starting,
          onChanged: controller.remoteRootChanged,
          decoration: InputDecoration(
            labelText: 'Folder on $deviceName',
            hintText: '~/notes',
            helperText: 'Exactly as granted there with `dsync pair grant`.',
            helperMaxLines: 4,
            errorText: state.remoteRootError,
          ),
        ),
        _Disclosure(
          key: const Key('run-setup-address-options'),
          title: 'Reach $deviceName at another address',
          children: [
            TextField(
              key: const Key('run-setup-address'),
              controller: address,
              enabled: !starting,
              decoration: InputDecoration(
                labelText: 'Address (optional)',
                hintText: 'host or host:port',
                helperText:
                    'Leave empty to use the address $deviceName was last '
                    'reached at.',
                helperMaxLines: 3,
                errorText: state.addressError,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          key: const Key('run-setup-dry-run'),
          title: const Text('Dry run'),
          subtitle: const Text('Show the plan, apply nothing.'),
          value: state.dryRun,
          onChanged: starting ? null : controller.setDryRun,
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('run-setup-profile-name'),
          controller: profileName,
          enabled: !starting,
          decoration: const InputDecoration(
            labelText: 'Save as profile (optional)',
            helperText:
                'Name this run and it lands on the home list, ready to '
                're-run with no typing.',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const Key('run-setup-save'),
            onPressed: starting ? null : onSave,
            child: const Text('Save without starting'),
          ),
        ),
        const SizedBox(height: 24),
        _OutcomeLine(state.outcome),
        FilledButton(
          key: const Key('run-setup-start'),
          onPressed: starting ? null : onStart,
          child: starting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  // The spinner replaces the button's label while the run
                  // is starting, so it has to say what the button now is.
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Starting the run',
                  ),
                )
              : const Text('Start'),
        ),
      ],
    );
  }
}

/// A required section's heading: the two sections the form cannot do
/// without carry more weight than the optional rows inside them.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleMedium);
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
  const _Disclosure({
    super.key,
    required this.title,
    required this.children,
  });

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

/// The line above the button for the outcome that has one. Started and
/// saved show nothing: the page is leaving.
class _OutcomeLine extends StatelessWidget {
  const _OutcomeLine(this.outcome);

  final RunSetupOutcome outcome;

  @override
  Widget build(BuildContext context) {
    return switch (outcome) {
      RunSetupFailed(:final message) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
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
