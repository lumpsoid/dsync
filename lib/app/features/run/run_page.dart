import 'package:flutter/material.dart';

/// The Run page: drive a run and render its `RunEvent`s (SPEC §9). Widgets
/// only, per the page role in `app_scope.dart`; its content lands with the
/// Run feature. This page owns its controller — it takes `runScope.create()`
/// and disposes it — for the reason given in the scope contract there.
class RunPage extends StatelessWidget {
  const RunPage({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
