import 'package:flutter/material.dart';

import '../../run_request.dart';
import 'run_setup_controller.dart';
import 'run_setup_scope.dart';
import 'run_setup_view_state.dart';

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
/// Run route. This page holds no `Navigator` of its own.
class RunSetupPage extends StatefulWidget {
  const RunSetupPage({super.key, required this.source, required this.onStart});

  /// What the form opens over: a device's blank form or a saved profile's
  /// pre-filled one.
  final RunSetupSource source;

  /// Called once when the request is built and the page should leave.
  final void Function(RunRequest request) onStart;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Run setup')),
      body: ListenableBuilder(
        listenable: _controller.state,
        builder: (context, _) => switch (_controller.state.peer) {
          RunSetupPeerLoading() => const Center(
            child: CircularProgressIndicator(),
          ),
          RunSetupPeerMissing(:final message) => Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          RunSetupPeerLoaded(:final name, :final grantHint) => _RunSetupForm(
            controller: _controller,
            deviceName: name,
            grantHint: grantHint,
            newFolder: _newFolder,
            remoteRoot: _remoteRoot,
            address: _address,
            profileName: _profileName,
            onCreateFolder: _createFolder,
            onPickFolder: _pickFolder,
            onStart: _start,
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
    required this.grantHint,
    required this.newFolder,
    required this.remoteRoot,
    required this.address,
    required this.profileName,
    required this.onCreateFolder,
    required this.onPickFolder,
    required this.onStart,
  });

  final RunSetupController controller;
  final String deviceName;
  final String? grantHint;
  final TextEditingController newFolder;
  final TextEditingController remoteRoot;
  final TextEditingController address;
  final TextEditingController profileName;
  final VoidCallback onCreateFolder;
  final VoidCallback onPickFolder;
  final VoidCallback onStart;

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
        const Text('On this device'),
        const SizedBox(height: 8),
        // A plain `DropdownButton` under an `InputDecorator` rather than a
        // `DropdownButtonFormField`: the form field keeps its own copy of
        // the selection and would not follow the controller selecting a
        // folder it just created.
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Folder',
            helperText: "A folder in this app's documents, or one you pick.",
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
                  child: Text(folder.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: starting ? null : controller.selectLocalFolder,
          ),
        ),
        const SizedBox(height: 8),
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
        const SizedBox(height: 24),
        Text('On $deviceName'),
        const SizedBox(height: 8),
        TextField(
          key: const Key('run-setup-remote-root'),
          controller: remoteRoot,
          enabled: !starting,
          onChanged: controller.remoteRootChanged,
          decoration: InputDecoration(
            labelText: 'Folder on $deviceName',
            hintText: '~/notes',
            helperText:
                grantHint ??
                'Exactly as granted there with `dsync pair grant`.',
            helperMaxLines: 4,
            errorText: state.remoteRootError,
          ),
        ),
        const SizedBox(height: 16),
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
        const SizedBox(height: 16),
        SwitchListTile(
          key: const Key('run-setup-dry-run'),
          title: const Text('Dry run'),
          subtitle: const Text('Show the plan, apply nothing.'),
          value: state.dryRun,
          onChanged: starting ? null : controller.setDryRun,
        ),
        const SizedBox(height: 24),
        _OutcomeLine(state.outcome),
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
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('run-setup-start'),
          onPressed: starting ? null : onStart,
          child: starting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Start'),
        ),
      ],
    );
  }
}

/// The line above the button for the outcome that has one. Started shows
/// nothing: the page is leaving.
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
      RunSetupStarted() => const SizedBox.shrink(),
    };
  }
}
