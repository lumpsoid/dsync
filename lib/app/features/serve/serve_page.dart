import 'package:flutter/material.dart';

import '../../shared_folder_row.dart';
import 'serve_controller.dart';
import 'serve_scope.dart';
import 'serve_view_state.dart';

/// Answering paired devices: the screen that makes this device the one a
/// run can be started *against* (SPEC §4.4).
///
/// Three things in the order the user needs them: whether this device is
/// answering and where, what it will serve and to whom, and what has
/// actually asked for something since it started.
///
/// **The listener lives and dies with this page.** It is bound on mount,
/// closed on the way out, and closed and re-bound across a background
/// pause — the same `paused`-not-`inactive` rule the Run page follows, and
/// the same property SPEC §4.4 gives the enrolment endpoint. So the switch
/// is not a preference that persists; it is this page's own toggle, and
/// leaving the page turns it off.
///
/// Widgets only, per the page role in `app_scope.dart`: the status is a
/// sealed case the controller decided, the folders are rows
/// `SharedFolderRow.renderAll` already rendered, and the devices that can
/// reach nothing arrive as a list of names rather than as a branch made
/// here.
///
/// A leaf: nothing leads anywhere from this page, so it takes no callbacks.
class ServePage extends StatefulWidget {
  const ServePage({super.key});

  @override
  State<ServePage> createState() => _ServePageState();
}

class _ServePageState extends State<ServePage> {
  final ServeController _controller = serveScope.create();

  /// The app's lifecycle, as the two calls this page makes on it. Held so
  /// it is disposed with the page: a listener that outlived the controller
  /// it re-binds would bind a socket for a page that is gone.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      // Only `paused`. `inactive` is a notification shade or a permission
      // dialog, and dropping a peer's session for one of those is the
      // failure `SyncRunController` refuses to make in the other direction.
      onPause: () => _controller.stop(),
      onResume: () => _controller.start(),
    );
    _controller.start();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Answer paired devices')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          _controller.app.state,
          _controller.state,
        ]),
        builder: (context, _) => _ServeBody(controller: _controller),
      ),
    );
  }
}

class _ServeBody extends StatelessWidget {
  const _ServeBody({required this.controller});

  final ServeController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.state.status;
    final folders = controller.folders;
    final reachingNothing = controller.devicesReachingNothing;
    final sessions = controller.state.sessions;
    return ListView(
      children: [
        _StatusTile(
          status: status,
          onChanged: (on) => on ? controller.start() : controller.stop(),
        ),
        const _SectionHeader('What this device serves'),
        if (folders.isEmpty)
          const ListTile(
            key: Key('serve-no-folders'),
            leading: Icon(Icons.folder_off_outlined),
            title: Text('No folder is shared with anyone.'),
            subtitle: Text(
              'A paired device that dials this one is refused every folder '
              'until it is shared from the Shared folders page. The refusal '
              'it sees says nothing about why.',
            ),
            isThreeLine: true,
          )
        else
          for (final folder in folders) _FolderTile(folder),
        if (reachingNothing.isNotEmpty)
          ListTile(
            key: const Key('serve-devices-reaching-nothing'),
            leading: const Icon(Icons.report_problem_outlined),
            title: Text(
              reachingNothing.length == 1
                  ? '${reachingNothing.single} may reach nothing here.'
                  : '${reachingNothing.join(', ')} may reach nothing here.',
            ),
            subtitle: const Text(
              'They are paired, so they can connect — and every folder they '
              'ask for is refused. Share a folder with them first.',
            ),
            isThreeLine: true,
          ),
        const _SectionHeader('Sessions'),
        if (sessions.isEmpty)
          const ListTile(
            key: Key('serve-no-sessions'),
            title: Text('Nothing has connected since this page opened.'),
          )
        else
          for (final line in sessions) ListTile(dense: true, title: Text(line)),
      ],
    );
  }
}

/// The toggle and what it currently says — the only branch in this file
/// over [ServeStatus], and it is a rendering of each case rather than a
/// decision about any of them.
class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.status, required this.onChanged});

  final ServeStatus status;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, subtitle, on, isError) = switch (status) {
      ServeStopped() => (
        'Not answering',
        'Other devices cannot start a run against this one while this is '
            'off, and this page is the only thing that turns it on.',
        false,
        false,
      ),
      ServeStarting() => ('Starting…', 'Opening the port.', true, false),
      ServeListening(:final address) => (
        'Answering at $address',
        'Type this on the other device if its saved address for this one no '
            'longer works. Paired devices only, each limited to the folders '
            'shared with it.',
        true,
        false,
      ),
      ServeFailed(:final message) => (message, 'Not answering.', false, true),
    };
    return SwitchListTile(
      key: const Key('serve-toggle'),
      value: on,
      onChanged: onChanged,
      secondary: Icon(
        isError ? Icons.error_outline : Icons.wifi_tethering,
        color: isError ? theme.colorScheme.error : null,
      ),
      title: Text(
        title,
        style: isError ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      subtitle: Text(subtitle),
      isThreeLine: true,
    );
  }
}

/// One folder this host serves, and who may reach it — the same row the
/// Shared folders page draws, read-only here: this page is about answering,
/// and granting has its own screen.
class _FolderTile extends StatelessWidget {
  const _FolderTile(this.folder);

  final SharedFolderRow folder;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('serve-folder-${folder.rootPath}'),
      leading: const Icon(Icons.folder_shared_outlined),
      title: Text(folder.label),
      subtitle: Text(folder.reachSummary),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}
