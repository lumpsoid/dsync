import 'package:flutter/material.dart';

import '../../run_request.dart';
import '../diagnostics/diagnostics_page.dart';
import 'run_setup_controller.dart';
import 'run_setup_scope.dart';
import 'run_setup_view_state.dart';

/// The Run setup page: pick the two locations a run syncs (SPEC §2, §4.4,
/// §11.2). Widgets only, per the page role in `app_scope.dart`: the chosen
/// folder with the button that changes it, three text fields, a switch, two
/// buttons, and switches over the rendered [RunSetupPeer] and
/// [RunSetupOutcome].
///
/// The layout is the decision order, in flat sections with no box drawn
/// around them — the heading groups the fields under it, as the Run page's
/// sections do. The two locations a run needs come first, at equal weight:
/// neither is optional and neither is a disclosure. What is optional (the
/// dry-run switch, SPEC §4.4's address hatch) is folded under a single
/// "Options". The two ways out are pinned in an action bar so neither
/// scrolls away, with Start filled and Save a text button beside it; the
/// profile name they both read is a field up in the form, so it belongs to
/// neither button.
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
    _remoteRoot.dispose();
    _address.dispose();
    _profileName.dispose();
    super.dispose();
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

  Future<void> _save() async {
    await _controller.save(
      remoteRoot: _remoteRoot.text,
      address: _address.text,
      profileName: _profileName.text,
    );
    if (!mounted) return;
    if (_controller.state.outcome is RunSetupSaved) widget.onSaved();
  }

  Future<void> _openDiagnostics(String rootPath) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DiagnosticsPage(rootPath: rootPath, blockedReason: null),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // The title says what the page is, not what is on it: the form
        // already names the device and both folders, so repeating them in
        // the chrome would only take the room a long device name needs.
        title: ListenableBuilder(
          listenable: _controller.state,
          builder: (context, _) =>
              Text(_title(_controller.state), overflow: TextOverflow.ellipsis),
        ),
        actions: [
          // The reachable entry to Diagnostics: the Run page carries the
          // same button, but that page only exists once a run has been
          // started, and a probe is refused while one is in flight — so
          // this is the only place a measurement can be taken *before* a
          // sync, which is when the question is usually asked.
          //
          // It needs the folder the probes would measure, so it waits for
          // one to be chosen rather than opening a page with nothing to
          // point at.
          ListenableBuilder(
            listenable: _controller.state,
            builder: (context, _) {
              final rootPath = _controller.state.localRoot;
              return IconButton(
                key: const Key('run-setup-diagnostics'),
                icon: const Icon(Icons.biotech_outlined),
                tooltip: rootPath == null
                    ? 'Diagnostics — pick a folder on this device first'
                    : 'Diagnostics',
                onPressed: rootPath == null
                    ? null
                    : () => _openDiagnostics(rootPath),
              );
            },
          ),
        ],
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
            editing: _controller.state.prefill != null,
            remoteRoot: _remoteRoot,
            address: _address,
            profileName: _profileName,
            onPickFolder: _pickFolder,
            onStart: _start,
            onSave: _save,
          ),
        },
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

class _RunSetupForm extends StatelessWidget {
  const _RunSetupForm({
    required this.controller,
    required this.deviceName,
    required this.editing,
    required this.remoteRoot,
    required this.address,
    required this.profileName,
    required this.onPickFolder,
    required this.onStart,
    required this.onSave,
  });

  final RunSetupController controller;
  final String deviceName;

  /// Whether the form was opened over a saved profile. Changes what saving
  /// is called and says — an edit writes back over the one profile — and
  /// nothing else: the fields and the rules are the same either way.
  final bool editing;
  final TextEditingController remoteRoot;
  final TextEditingController address;
  final TextEditingController profileName;
  final VoidCallback onPickFolder;
  final VoidCallback onStart;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final starting = state.outcome is RunSetupStarting;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Flat sections, no card: the page is the container. The Run
              // page's own sections read the same way (`_Section` there),
              // and a form whose fields are boxed inside a box inside a
              // disclosure is three frames drawn around two decisions.
              _SectionLabel('On this device'),
              const SizedBox(height: 8),
              // The chosen folder shown as a value, not a control: there
              // is one way to set it — the platform chooser — so there is
              // no list to choose from and nothing to type. The button
              // beside it is that one way, in the open.
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Folder',
                        errorText: state.localFolderError,
                      ),
                      child: Text(
                        key: const Key('run-setup-local-folder'),
                        state.localRoot ?? 'No folder chosen',
                        overflow: TextOverflow.ellipsis,
                        style: state.localRoot == null
                            ? TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('run-setup-pick-folder'),
                    onPressed: starting ? null : onPickFolder,
                    child: Text(
                      state.localRoot == null ? 'Pick a folder…' : 'Change',
                    ),
                  ),
                ],
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
                  labelText: 'Folder',
                  hintText: '~/notes',
                  helperText:
                      'Exactly as granted there with `dsync pair grant`.',
                  helperMaxLines: 4,
                  errorText: state.remoteRootError,
                ),
              ),
              const SizedBox(height: 24),
              // The name sits with the fields it names, not with the
              // buttons: it is part of what gets saved, and both ways out
              // of the page read it.
              TextField(
                key: const Key('run-setup-profile-name'),
                controller: profileName,
                enabled: !starting,
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
