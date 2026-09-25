import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'run_controller.dart';

/// Opens the Timings sheet over the Run page (SPEC §17).
///
/// A modal sheet rather than a route, for the reason `RunPage`'s own doc
/// comment gives: that page holds no `Navigator` of its own. This one is
/// *modal* and stacks over the page, the review's bar (SPEC §11.3)
/// included.
Future<void> showRunTimings(
  BuildContext context,
  SyncRunController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => RunTimingsSheet(controller: controller),
);

/// Where the run went, on the device it went there on (SPEC §17).
///
/// **Why the head needs this at all.** The CLI prints the same report
/// behind `--timings`, but this head's whole cost profile — a phone's flash
/// for every archive commit, a phone's radio for every round trip — exists
/// nowhere else and cannot be simulated from a laptop.
///
/// **The core's report, verbatim** (plan D11): phase spans, per-operation
/// count, total, mean and max per replica, bytes, the served write-stage
/// summary, the writer pool's stage timings and CPU per MiB — the same text
/// `dsync sync --timings` prints, so a phone's report and a desktop's are
/// read side by side, and the copy button hands over exactly that. The
/// core reports it when the run ends; until then the sheet says so.
class RunTimingsSheet extends StatelessWidget {
  const RunTimingsSheet({super.key, required this.controller});

  final SyncRunController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ValueListenableBuilder<String?>(
          valueListenable: controller.timings,
          builder: (context, report, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Timings', style: theme.textTheme.titleLarge),
                    ),
                    IconButton(
                      key: const Key('run-timings-copy'),
                      icon: const Icon(Icons.copy_all),
                      tooltip: 'Copy report',
                      onPressed: report == null
                          ? null
                          : () => _copy(context, report),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: report == null
                      ? Text(
                          'The timings are reported when the run ends.',
                          key: const Key('run-timings-pending'),
                          style: theme.textTheme.bodyMedium,
                        )
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            report,
                            key: const Key('run-timings-report'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context, String report) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: report));
    messenger.showSnackBar(
      const SnackBar(content: Text('Timings report copied')),
    );
  }
}
