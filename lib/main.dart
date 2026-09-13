import 'package:dsync/app/dsync_app.dart';
import 'package:flutter/material.dart';

/// Entrypoint of the Flutter head. Flutter requires this file at this path;
/// the head itself lives under `lib/app/` per SPEC §13.
void main() {
  runApp(const DsyncApp());
}
