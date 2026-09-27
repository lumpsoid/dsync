import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../readable_width.dart';
import '../../shell_layout.dart';
import 'run_controller.dart';

/// Opens the Timings report over the Run page (SPEC §17): a bottom sheet on
/// a phone-sized window, a dialog on a [windowWidth] that gets the shell's
/// rail.
///
/// Modal rather than a route, for the reason `RunPage`'s own doc comment
/// gives: that page holds no `Navigator` of its own. Either form is
/// *modal* and stacks over the page, the review's bar (SPEC §11.3)
/// included.
///
/// **A dialog from the rail's breakpoint, not the table's.** On a monitor a
/// bottom sheet is a bar pinned to the window's lower edge with a handle no
/// mouse drags, and the report — read across its columns — ends up as far
/// from the pointer as the window allows. Material hands a modal sheet over
/// to a dialog at the expanded window class, which is where the shell
/// grows its rail ([ShellLayout.railMinWidth]); the Run page's own
/// `RunLayout` waits for the large class for a reason about table columns
/// that a report does not share. The page reads its width once and passes
/// it here, so this is the one place the breakpoint is applied to it.
Future<void> showRunTimings(
  BuildContext context,
  SyncRunController controller, {
  required double windowWidth,
}) {
  if (windowWidth >= ShellLayout.railMinWidth) {
    return showDialog<void>(
      context: context,
      builder: (context) => RunTimingsDialog(controller: controller),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => RunTimingsSheet(controller: controller),
  );
}

/// Where the run went, on the device it went there on (SPEC §17) — as a
/// sheet, on a phone.
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
                    _CopyReportButton(report: report, labelled: false),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _TimingsReport(report: report),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The same report as [RunTimingsSheet], as a dialog on a wide window.
///
/// **Sized for the report, not for a question.** An `AlertDialog` sizes
/// itself to its content's intrinsic width, which a scrolling report has
/// none of; this one takes the [ReadableWidth.list] column — room for the
/// core's widest table at the report's size — so it neither jumps when the
/// report arrives nor stretches across a monitor. The report scrolls inside
/// it both ways.
///
/// **Copy and Close as its actions**, where a desktop dialog keeps them;
/// Esc and a click outside close it too, as they do every dialog.
class RunTimingsDialog extends StatelessWidget {
  const RunTimingsDialog({super.key, required this.controller});

  final SyncRunController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: SizedBox(
        width: ReadableWidth.list.maxWidth,
        child: ValueListenableBuilder<String?>(
          valueListenable: controller.timings,
          builder: (context, report, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                child: Text('Timings', style: theme.textTheme.headlineSmall),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _TimingsReport(report: report),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _CopyReportButton(report: report, labelled: true),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('run-timings-close'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A monospace face on every platform the app ships to.
///
/// `monospace` is a generic alias, not a font: Android and Linux's
/// fontconfig resolve it, Windows and macOS do not, and the report's
/// columns only align in a fixed-pitch face. So the fallbacks name one
/// font each platform is known to carry — Menlo (macOS and iOS), Consolas
/// (Windows), DejaVu Sans Mono (the Linux default, should the alias be
/// unset) — with Courier New last, present on both Windows and macOS.
const _monospaceFallback = [
  'Menlo',
  'Consolas',
  'DejaVu Sans Mono',
  'Courier New',
];

/// The report in a fixed-pitch face, or a line saying it comes when the run
/// ends.
///
/// **Selectable, not just copyable.** A [SelectionArea] lets a user lift one
/// phase's line or one replica's column into a bug report, rather than the
/// whole report or nothing; the report scrolls sideways rather than wrap,
/// since a wrapped row no longer lines up with its header.
class _TimingsReport extends StatelessWidget {
  const _TimingsReport({required this.report});

  final String? report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = this.report;
    if (report == null) {
      return Text(
        'The timings are reported when the run ends.',
        key: const Key('run-timings-pending'),
        style: theme.textTheme.bodyMedium,
      );
    }
    return SelectionArea(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          report,
          key: const Key('run-timings-report'),
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: _monospaceFallback,
          ),
        ),
      ),
    );
  }
}

/// Copies the whole report, and says so on the button itself for a moment.
///
/// **On the button, not in a snack bar.** The snack bar would show in the
/// Run page's `Scaffold`, under the modal barrier — behind the sheet
/// entirely, dimmed behind the dialog — so the confirmation goes where the
/// user is looking. [labelled] is the dialog's text button; otherwise it is
/// the sheet header's icon.
class _CopyReportButton extends StatefulWidget {
  const _CopyReportButton({required this.report, required this.labelled});

  /// Null until the core reports it, and nothing to copy until then.
  final String? report;

  final bool labelled;

  @override
  State<_CopyReportButton> createState() => _CopyReportButtonState();
}

class _CopyReportButtonState extends State<_CopyReportButton> {
  /// How long the button reads "Copied" before it offers the copy again.
  static const _confirmationTime = Duration(seconds: 2);

  Timer? _reset;

  bool get _copied => _reset?.isActive ?? false;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy(String report) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    _reset?.cancel();
    setState(() {
      _reset = Timer(_confirmationTime, () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final onPressed = report == null ? null : () => _copy(report);
    final icon = Icon(_copied ? Icons.check : Icons.copy_all);
    if (widget.labelled) {
      return TextButton.icon(
        key: const Key('run-timings-copy'),
        icon: icon,
        label: Text(_copied ? 'Copied' : 'Copy'),
        onPressed: onPressed,
      );
    }
    return IconButton(
      key: const Key('run-timings-copy'),
      icon: icon,
      tooltip: _copied ? 'Copied' : 'Copy report',
      onPressed: onPressed,
    );
  }
}
