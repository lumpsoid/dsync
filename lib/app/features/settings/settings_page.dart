import 'package:material_ui/material_ui.dart';

import '../../copy_value_button.dart';
import '../../readable_width.dart';
import '../../theme_preference.dart';
import '../../warn_size.dart';
import 'settings_controller.dart';
import 'settings_scope.dart';
import 'settings_view_state.dart';

/// What this installation keeps for itself, in sections: **Network**,
/// holding the address the pairing listener binds (task 2b26ac's `--bind`,
/// as the head's own setting) and the port this device serves on,
/// **Appearance**, holding the theme,
/// **Power**, holding whether runs and serve keep the screen awake,
/// **Sync**, holding the size a run's review warns above, and
/// **Deletion safety**, holding when a run stops to ask before deleting —
/// its thresholds only: the guard has no off switch here — and
/// **Diagnostics**, which shows this build's version and copies what a user
/// attaches to a bug report.
///
/// Widgets only, per the page role in `app_scope.dart`: the stored settings
/// arrive as one value the controller has already parsed, and the only
/// branches here are over whether they were read and the sealed
/// [SettingsOutcome]. Nothing on this page decides what a bind address, a
/// port, a warn size or a delete threshold may be — the dialog hands what
/// was typed to the controller, and the refusal it shows is
/// `parseBindAddress`'s, `PeerPort.parse`'s, `WarnSize.parse`'s or
/// `MassDeleteGuard`'s own words.
///
/// A leaf: nothing leads anywhere from this page, so it takes no callbacks.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsController _controller = settingsScope.controller;

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // Selectable as a page (`CopyValueButton` states the rule): the
      // notices are read-only, and the setting's own row opts out.
      body: SelectionArea(
        child: ListenableBuilder(
          listenable: _controller.state,
          builder: (context, _) => _SettingsBody(controller: _controller),
        ),
      ),
    );
  }
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody({required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final outcome = state.outcome;
    final working = outcome is SettingsWorking;
    final bindAddress = state.settings?.bindAddress.address;
    final peerPort = state.settings?.peerPort;
    final theme = state.settings?.theme;
    final keepScreenAwake = state.settings?.keepScreenAwake;
    final warnSize = state.settings?.warnSize;
    final guard = state.settings?.massDeleteGuard;
    return ReadableScrollPadding(
      width: ReadableWidth.list,
      padding: null,
      builder: (context, padding) => ListView(
        padding: padding,
        children: [
          const _SectionHeader('Network'),
          SelectionContainer.disabled(
            child: ListTile(
              key: const Key('settings-bind-address'),
              leading: const Icon(Icons.lan_outlined),
              title: const Text('Pairing bind address'),
              subtitle: Text(
                bindAddress == null
                    ? 'Unavailable — see below.'
                    : '$bindAddress\nWhich of this device\'s '
                          'addresses the pairing code listens on. 0.0.0.0 is '
                          'every IPv4 interface; one interface\'s own address '
                          'is also what the code advertises.',
              ),
              isThreeLine: bindAddress != null,
              enabled: !working && bindAddress != null,
              onTap: () => _editBindAddress(context, bindAddress ?? ''),
            ),
          ),
          SelectionContainer.disabled(
            child: ListTile(
              key: const Key('settings-peer-port'),
              leading: const Icon(Icons.settings_ethernet_outlined),
              title: const Text('Peer port'),
              subtitle: Text(
                peerPort == null
                    ? 'Unavailable — see below.'
                    : '$peerPort\nThe port this device serves paired devices '
                          'on, and the one its pairing codes tell them to '
                          'dial.',
              ),
              isThreeLine: peerPort != null,
              enabled: !working && peerPort != null,
              onTap: () => _editPeerPort(context, '${peerPort ?? ''}'),
            ),
          ),
          const _SectionHeader('Appearance'),
          SelectionContainer.disabled(
            child: ListTile(
              key: const Key('settings-theme'),
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('Theme'),
              enabled: !working && theme != null,
              subtitle: switch (theme) {
                null => const Text('Unavailable — see below.'),
                // Three fixed choices, each applied the moment it is
                // picked: shown side by side rather than behind a dialog.
                final theme => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SegmentedButton<ThemePreference>(
                      key: const Key('settings-theme-choice'),
                      segments: const [
                        ButtonSegment(
                          value: ThemePreference.system,
                          label: Text('System'),
                        ),
                        ButtonSegment(
                          value: ThemePreference.light,
                          label: Text('Light'),
                        ),
                        ButtonSegment(
                          value: ThemePreference.dark,
                          label: Text('Dark'),
                        ),
                      ],
                      selected: {theme},
                      onSelectionChanged: working
                          ? null
                          : (selection) =>
                                controller.saveTheme(selection.single),
                    ),
                  ),
                ),
              },
            ),
          ),
          const _SectionHeader('Power'),
          SelectionContainer.disabled(
            child: switch (keepScreenAwake) {
              null => const ListTile(
                key: Key('settings-keep-screen-awake'),
                leading: Icon(Icons.screen_lock_portrait_outlined),
                title: Text(_keepScreenAwakeTitle),
                subtitle: Text('Unavailable — see below.'),
                enabled: false,
              ),
              final on => SwitchListTile(
                key: const Key('settings-keep-screen-awake'),
                secondary: const Icon(Icons.screen_lock_portrait_outlined),
                title: const Text(_keepScreenAwakeTitle),
                subtitle: const Text(
                  'The screen timing out pauses a live sync and stops '
                  'serving.',
                ),
                value: on,
                onChanged: working ? null : controller.saveKeepScreenAwake,
              ),
            },
          ),
          const _SectionHeader('Sync'),
          SelectionContainer.disabled(
            child: ListTile(
              key: const Key('settings-warn-size'),
              leading: const Icon(Icons.data_usage_outlined),
              title: const Text('Warn about large transfers'),
              subtitle: Text(switch (warnSize) {
                null => 'Unavailable — see below.',
                WarnSizeOff() =>
                  'Off\nA sync warns before it applies only when its '
                      'profile sets a size.',
                final WarnSizeAbove size =>
                  'Above ${size.label}\nA sync that '
                      'moves more warns before you apply it, unless its '
                      'profile sets a size of its own.',
              }),
              isThreeLine: warnSize != null,
              enabled: !working && warnSize != null,
              onTap: () => _editWarnSize(context, switch (warnSize) {
                final WarnSizeAbove size => size.typed,
                WarnSizeOff() || null => '',
              }),
            ),
          ),
          const _SectionHeader('Deletion safety'),
          SelectionContainer.disabled(
            child: ListTile(
              key: const Key('settings-mass-delete-min-files'),
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Ask before deleting from'),
              subtitle: Text(
                guard == null
                    ? 'Unavailable — see below.'
                    : '${guard.minFiles} files on one side\nA sync stops to '
                          'ask before it deletes this many files or more on '
                          'one side, when they are also over the share '
                          'below.',
              ),
              isThreeLine: guard != null,
              enabled: !working && guard != null,
              onTap: () =>
                  _editMassDeleteMinFiles(context, '${guard?.minFiles ?? ''}'),
            ),
          ),
          SelectionContainer.disabled(
            child: ListTile(
              key: const Key('settings-mass-delete-percent'),
              leading: const Icon(Icons.pie_chart_outline),
              title: const Text('…and over this share of a side'),
              subtitle: Text(
                guard == null
                    ? 'Unavailable — see below.'
                    : '${guard.percent}% of its files\nOf the files that '
                          'side last synced. These tune when dsync asks; '
                          'it always asks past them, and never deletes that '
                          'much without your say-so.',
              ),
              isThreeLine: guard != null,
              enabled: !working && guard != null,
              onTap: () =>
                  _editMassDeletePercent(context, '${guard?.percent ?? ''}'),
            ),
          ),
          const _SectionHeader('Diagnostics'),
          ListTile(
            key: const Key('settings-version'),
            leading: const Icon(Icons.info_outline),
            title: const Text('Version'),
            subtitle: Text(state.version ?? 'Unknown'),
          ),
          SelectionContainer.disabled(
            child: ListTile(
              key: const Key('settings-copy-diagnostics'),
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Copy diagnostics'),
              subtitle: const Text(
                'This app\'s version and platform, and its recent errors and '
                'sync events, to paste into a bug report. No file contents, '
                'and not the list of files a sync touched.',
              ),
              isThreeLine: true,
              enabled: !working,
              onTap: () => _copyDiagnostics(context),
            ),
          ),
          switch (outcome) {
            SettingsSaved(:final message) => _NoticeTile(
              message,
              isError: false,
            ),
            SettingsFailed(:final message) => _NoticeTile(
              message,
              isError: true,
            ),
            SettingsIdle() || SettingsWorking() => const SizedBox.shrink(),
          },
          if (working)
            const ListTile(
              title: LinearProgressIndicator(
                semanticsLabel: 'Saving your settings',
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _copyDiagnostics(BuildContext context) async {
    final text = await controller.readDiagnostics();
    if (text == null || !context.mounted) return;
    await copyValue(context, value: text, what: 'diagnostics');
  }

  Future<void> _editBindAddress(BuildContext context, String current) async {
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => _TypedValueDialog(
        title: 'Pairing bind address',
        label: 'Address',
        help:
            'An address this device has, not a name: 0.0.0.0 for every IPv4 '
            'interface, :: for every interface of either family, or one '
            'interface\'s own address to pair over just that network.',
        keyPrefix: 'settings-bind-address',
        initialValue: current,
      ),
    );
    if (typed != null) await controller.saveBindAddress(typed);
  }

  Future<void> _editPeerPort(BuildContext context, String current) async {
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => _TypedValueDialog(
        title: 'Peer port',
        label: 'Port',
        help:
            'A number from 1 to 65535. Devices paired before a change still '
            'dial the port they recorded, until their address is edited.',
        keyPrefix: 'settings-peer-port',
        initialValue: current,
        keyboardType: TextInputType.number,
      ),
    );
    if (typed != null) await controller.savePeerPort(typed);
  }

  Future<void> _editWarnSize(BuildContext context, String current) async {
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => _TypedValueDialog(
        title: 'Warn about large transfers',
        label: 'Size',
        help:
            'Warn when a sync moves more than this — e.g. 500 MB or 2 GiB; '
            'empty for off. A '
            'profile\'s own warn size, where it sets one, is used instead.',
        keyPrefix: 'settings-warn-size',
        initialValue: current,
        keyboardType: TextInputType.number,
      ),
    );
    if (typed != null) await controller.saveWarnSize(typed);
  }

  Future<void> _editMassDeleteMinFiles(
    BuildContext context,
    String current,
  ) async {
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => _TypedValueDialog(
        title: 'Ask before deleting from',
        label: 'Files',
        help:
            'A whole number of at least 1. A sync that would delete this '
            'many files or more on one side — and over the share of that '
            'side — stops and asks you first.',
        keyPrefix: 'settings-mass-delete-min-files',
        initialValue: current,
        keyboardType: TextInputType.number,
      ),
    );
    if (typed != null) await controller.saveMassDeleteMinFiles(typed);
  }

  Future<void> _editMassDeletePercent(
    BuildContext context,
    String current,
  ) async {
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => _TypedValueDialog(
        title: '…and over this share of a side',
        label: 'Percent',
        help:
            'A whole number from 1 to 100. A sync that would delete more '
            'than this share of the files a side last synced — and at least '
            'the file count — stops and asks you first.',
        keyPrefix: 'settings-mass-delete-percent',
        initialValue: current,
        keyboardType: TextInputType.number,
      ),
    );
    if (typed != null) await controller.saveMassDeletePercent(typed);
  }
}

const _keepScreenAwakeTitle = 'Keep screen awake during runs and serve';

/// A settings section's name: what tells a reader which of this device's
/// behaviours the settings under it change.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// A typed setting — the bind address, the peer port, the warn size or a
/// delete threshold — popped as text.
/// Pops nothing at all when cancelled, and does not judge what was typed:
/// the refusal belongs to the value's own parse through
/// `SettingsController`, so there is one rule about each value rather than
/// two.
class _TypedValueDialog extends StatefulWidget {
  const _TypedValueDialog({
    required this.title,
    required this.label,
    required this.help,
    required this.keyPrefix,
    required this.initialValue,
    this.keyboardType,
  });

  final String title;
  final String label;
  final String help;

  /// The field is `$keyPrefix-field`, the save button `$keyPrefix-save`.
  final String keyPrefix;
  final String initialValue;
  final TextInputType? keyboardType;

  @override
  State<_TypedValueDialog> createState() => _TypedValueDialogState();
}

class _TypedValueDialogState extends State<_TypedValueDialog> {
  late final TextEditingController _value = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: Key('${widget.keyPrefix}-field'),
            controller: _value,
            autofocus: true,
            keyboardType: widget.keyboardType,
            decoration: InputDecoration(labelText: widget.label),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          const SizedBox(height: 16),
          Text(widget.help),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: Key('${widget.keyPrefix}-save'),
          onPressed: () => Navigator.of(context).pop(_value.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// An error or confirmation line, in the theme's colour for it.
class _NoticeTile extends StatelessWidget {
  const _NoticeTile(this.message, {required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        isError ? Icons.error_outline : Icons.info_outline,
        color: isError ? scheme.error : scheme.tertiary,
      ),
      title: Text(message, key: const Key('settings-notice')),
    );
  }
}
