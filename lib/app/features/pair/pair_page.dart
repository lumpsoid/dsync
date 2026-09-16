import 'package:flutter/material.dart';

import 'pair_scope.dart';
import 'pair_view_state.dart';

/// The Pair page: enrol against a `dsync-pair:v1:` payload (SPEC §4.4).
/// Widgets only, per the page role in `app_scope.dart`: three text fields,
/// one button, and a switch over the rendered [PairOutcome].
///
/// The payload arrives as text this phase — the line `dsync pair show`
/// prints beside its QR, pasted — which is the whole flow with no camera,
/// so it runs on a desktop build and an emulator. A scanner is a second
/// input method on this same page later, feeding the same
/// `PairController.submitPayload`.
///
/// [onPaired] is the seam back to Devices: the controller has refreshed
/// `AppState.devices` by the time it fires, so the destination needs
/// nothing handed to it. The entrypoint wires it to a pop; this page holds
/// no `Navigator` of its own.
class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.onPaired});

  /// Called once after a successful pairing, when the page should leave.
  final VoidCallback onPaired;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _payload = TextEditingController();
  final _localName = TextEditingController();
  final _proposedName = TextEditingController();

  @override
  void dispose() {
    _payload.dispose();
    _localName.dispose();
    _proposedName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = pairScope.controller;
    await controller.submitPayload(
      payloadText: _payload.text,
      localName: _localName.text,
      proposedName: _proposedName.text,
    );
    if (!mounted) return;
    if (controller.state.outcome is PairSucceeded) widget.onPaired();
  }

  @override
  Widget build(BuildContext context) {
    final controller = pairScope.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Pair a device')),
      body: ListenableBuilder(
        listenable: controller.state,
        builder: (context, _) => _PairForm(
          state: controller.state,
          payload: _payload,
          localName: _localName,
          proposedName: _proposedName,
          onSubmit: _submit,
        ),
      ),
    );
  }
}

class _PairForm extends StatelessWidget {
  const _PairForm({
    required this.state,
    required this.payload,
    required this.localName,
    required this.proposedName,
    required this.onSubmit,
  });

  final PairViewState state;
  final TextEditingController payload;
  final TextEditingController localName;
  final TextEditingController proposedName;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final submitting = state.outcome is PairSubmitting;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'On the desktop, run `dsync pair show` and paste the '
          '`dsync-pair:v1:` line it prints.',
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('pair-payload'),
          controller: payload,
          enabled: !submitting,
          maxLines: null,
          decoration: const InputDecoration(
            labelText: 'Pairing payload',
            hintText: 'dsync-pair:v1:…',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('pair-local-name'),
          controller: localName,
          enabled: !submitting,
          decoration: InputDecoration(
            labelText: 'Name for the desktop',
            helperText: 'What this device will show it as.',
            errorText: state.localNameError,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('pair-proposed-name'),
          controller: proposedName,
          enabled: !submitting,
          decoration: InputDecoration(
            labelText: 'Name for this device',
            helperText: 'What the desktop will show this device as.',
            errorText: state.proposedNameError,
          ),
        ),
        const SizedBox(height: 24),
        _OutcomeLine(state.outcome),
        FilledButton(
          onPressed: submitting ? null : onSubmit,
          child: submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Pair'),
        ),
      ],
    );
  }
}

/// The line above the button for the outcome that has one. Success shows
/// nothing: the page is leaving.
class _OutcomeLine extends StatelessWidget {
  const _OutcomeLine(this.outcome);

  final PairOutcome outcome;

  @override
  Widget build(BuildContext context) {
    return switch (outcome) {
      PairFailed(:final message) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      PairSubmitting() => const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Text('Connecting to the desktop…'),
      ),
      PairIdle() || PairSucceeded() => const SizedBox.shrink(),
    };
  }
}
