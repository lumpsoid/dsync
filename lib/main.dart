import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/dsync_app.dart';
import 'package:dsync/app/rust/bindings/bindings.dart';
import 'package:dsync/app/uncaught_errors.dart';
import 'package:flutter/material.dart';
import 'package:rinf/rinf.dart';

/// Entrypoint of the Flutter head. Flutter requires this file at this path;
/// the head itself lives under `lib/app/` per SPEC §13.
///
/// Bootstrap is kicked off here, not by a widget: `DsyncApp` renders
/// whatever `AppState.bootstrap` says and never starts the sequence itself,
/// so a widget test can pin a controller through `appScope` and drive the
/// gate by hand. The binding must be up first because resolving the
/// support directory goes through a platform channel (`path_provider`).
/// The future is not awaited: the loading screen is what shows until it
/// lands.
///
/// The Rust core (native/hub) is started before any of that: it only loads
/// the library and parks on its signal receivers until the bootstrap's
/// `init` reaches it through `appScope`'s `CoreLink` over the
/// `RinfCoreChannel` (plan D10). Uncaught errors are noted in the core's
/// diagnostics log from then on; one raised before `init` lands is lost.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeRust(assignRustSignal);
  noteUncaughtErrors(appScope.controller.core);
  appScope.controller.bootstrap();
  runApp(const DsyncApp());
}
