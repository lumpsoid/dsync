import 'package:dsync/app/app_scope.dart';
import 'package:dsync/app/dsync_app.dart';
import 'package:flutter/material.dart';

/// Entrypoint of the Flutter head. Flutter requires this file at this path;
/// the head itself lives under `lib/app/` per SPEC §13.
///
/// Bootstrap is kicked off here, not by a widget: `DsyncApp` renders
/// whatever `AppState.bootstrap` says and never starts the sequence itself,
/// so a widget test can pin a controller through `appScope` and drive the
/// gate by hand. The binding must be up first because resolving the paths
/// goes through a platform channel (`path_provider`). The future is not
/// awaited: the loading screen is what shows until it lands.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  appScope.controller.bootstrap();
  runApp(const DsyncApp());
}
