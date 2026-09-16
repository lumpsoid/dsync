import 'package:flutter/material.dart';

import '../../run_request.dart';
import 'run_setup_controller.dart';
import 'run_setup_scope.dart';
import 'run_setup_view_state.dart';

/// The Run setup page: pick the two locations a run syncs (SPEC §2, §4.4,
/// §11.2). Widgets only, per the page role in `app_scope.dart`: a folder
/// picker, three text fields, a switch, one button, and switches over the
/// rendered [RunSetupPeer] and [RunSetupOutcome].
///
/// Opened for a device by [deviceId] — the Devices page hands over the id
/// and `RunSetupController.load` reads what it needs, resetting the
/// selection and the dry-run choice to this visit's. The cached scope
/// controller, as the Pair page uses, rather than `create()`: `load` is
/// asynchronous, and a controller disposed by a page that left early would
/// have its view state written to after disposal.
///
/// [onStart] is the seam to the Run feature: it fires once with the
/// [RunRequest] the controller built, and the entrypoint wires it to the
/// Run route. This page holds no `Navigator` of its own.
class RunSetupPage extends StatefulWidget {
  const RunSetupPage({
    super.key,
    required this.deviceId,
    required this.onStart,
  });

  /// The grouped device id of the peer to set a run up against.
  final String deviceId;

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

  @override
  void initState() {
    super.initState();
    _controller.load(widget.deviceId);
  }

  @override
  void dispose() {
    _newFolder.dispose();
    _remoteRoot.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    await _controller.createLocalFolder(_newFolder.text);
    if (!mounted) return;
    if (_controller.state.newFolderError == null) _newFolder.clear();
  }

  Future<void> _start() async {
    await _controller.start(
      remoteRoot: _remoteRoot.text,
      address: _address.text,
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
            onCreateFolder: _createFolder,
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
    required this.onCreateFolder,
    required this.onStart,
  });

  final RunSetupController controller;
  final String deviceName;
  final String? grantHint;
  final TextEditingController newFolder;
  final TextEditingController remoteRoot;
  final TextEditingController address;
  final VoidCallback onCreateFolder;
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
            helperText: "A folder in this app's documents.",
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
                DropdownMenuItem(value: folder, child: Text(folder)),
            ],
            onChanged: starting ? null : controller.selectLocalFolder,
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
