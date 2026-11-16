import 'package:material_ui/material_ui.dart';

import '../../readable_width.dart';
import 'devices_scope.dart';

/// What the pane beside the device list shows while no device is selected
/// there: a line saying what selecting one gives, rather than a blank half
/// of the window that reads as something failing to load.
///
/// The line reads the list it sits beside, because "select a device" beside
/// an empty list points at nothing: with no paired device it says what
/// comes first instead. The list's own empty state carries the Pair button,
/// so this pane does not offer a second one.
///
/// A bar with no title keeps the pane's top edge where a device's page puts
/// its own, so selecting one changes the pane's content, not its shape.
class NoDeviceSelected extends StatelessWidget {
  const NoDeviceSelected({super.key});

  @override
  Widget build(BuildContext context) {
    final state = devicesScope.controller.app.state;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: Center(
        child: ReadableColumn(
          width: ReadableWidth.form,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.devices_outlined,
                  size: 48,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(height: 16),
                ListenableBuilder(
                  listenable: state,
                  builder: (context, _) => Text(
                    state.devices.isEmpty
                        ? 'Once a device is paired, select it in the list to '
                              'see its folders, its certificate and its name '
                              'here.'
                        : 'Select a device in the list to see its folders, '
                              'its certificate and its name here.',
                    key: const Key('devices-no-selection'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
