import 'package:flutter/material.dart';

import '../../readable_width.dart';
import '../../theme_preference.dart';
import 'settings_controller.dart';
import 'settings_scope.dart';
import 'settings_view_state.dart';

/// What this installation keeps for itself, in sections: **Network**,
/// holding the address the pairing listener binds (task 2b26ac's `--bind`,
/// as the head's own setting), **Appearance**, holding the theme, and
/// **Power**, holding whether runs and serve keep the screen awake.
///
/// Widgets only, per the page role in `app_scope.dart`: the stored settings
/// arrive as one value the controller has already parsed, and the only
/// branches here are over whether they were read and the sealed
/// [SettingsOutcome]. Nothing on this page decides what a bind address may
/// be — the dialog hands what was typed to the controller, and the refusal
/// it shows is `parseBindAddress`'s own words.
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
    final theme = state.settings?.theme;
    final keepScreenAwake = state.settings?.keepScreenAwake;
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

  Future<void> _editBindAddress(BuildContext context, String current) async {
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => _BindAddressDialog(initialValue: current),
    );
    if (typed != null) await controller.saveBindAddress(typed);
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

/// The typed address, popped as text. Pops nothing at all when cancelled,
/// and does not judge what was typed: the refusal belongs to
/// `parseBindAddress` through `SettingsController`, so there is one rule
/// about a bind address rather than two.
class _BindAddressDialog extends StatefulWidget {
  const _BindAddressDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_BindAddressDialog> createState() => _BindAddressDialogState();
}

class _BindAddressDialogState extends State<_BindAddressDialog> {
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
      title: const Text('Pairing bind address'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('settings-bind-address-field'),
            controller: _value,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Address'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          const SizedBox(height: 16),
          const Text(
            'An address this device has, not a name: 0.0.0.0 for every IPv4 '
            'interface, :: for every interface of either family, or one '
            'interface\'s own address to pair over just that network.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('settings-bind-address-save'),
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
