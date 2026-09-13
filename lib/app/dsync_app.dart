import 'package:dsync/dsync_core/protocol/version_handshake.dart';
import 'package:flutter/material.dart';

/// The Flutter head, deferred to a skeleton for v0 (SPEC §13, §16).
///
/// Its only job today is to exist and to compile against `dsync_core`, which
/// is what keeps the core free of any Flutter dependency honest: if something
/// head-specific ever leaked into `dsync_core/`, this file is where it would
/// show up as a dependency cycle. The real UI arrives with the transport the
/// Flutter head needs (SPEC §16) — it cannot rely on a system `ssh` binary,
/// so there is nothing to drive a run with yet.
class DsyncApp extends StatelessWidget {
  const DsyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dsync',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.teal)),
      home: const _DeferredHead(),
    );
  }
}

class _DeferredHead extends StatelessWidget {
  const _DeferredHead();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('dsync')),
      body: Center(
        child: Text(
          'Flutter head deferred (SPEC §16).\n'
          'Core protocol version $protocolVersion.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
