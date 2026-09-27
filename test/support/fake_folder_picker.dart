import 'package:dsync/app/features/run_setup/folder_picker.dart';

/// A [FolderPicker] a test drives: it answers with whatever the test set,
/// and counts what it was asked.
///
/// The interface exists because the real picker is two platform channels
/// (see `folder_picker.dart`), so this is the fake that stands in for both.
/// [onRequestAccess] is a callback rather than a `bool` so a test can make
/// the grant *do* something — create the folder the probe is about to fail
/// on — which is how "refused, granted, then usable" is exercised without
/// touching real permissions.
class FakeFolderPicker implements FolderPicker {
  /// What the chooser returns; `null` is the user dismissing it.
  String? Function() onPick = () => null;

  /// What asking for the grant does, and whether it was given.
  Future<bool> Function() onRequestAccess = () async => false;

  /// Whether this stands in for a phone, which has a grant and a Settings
  /// page to give it on, or for a desktop, which has neither.
  @override
  bool asksForFileAccess = true;

  int pickCount = 0;
  int requestAccessCount = 0;
  int openSettingsCount = 0;

  @override
  Future<String?> pick() async {
    pickCount++;
    return onPick();
  }

  @override
  Future<bool> requestAccess() {
    requestAccessCount++;
    return onRequestAccess();
  }

  @override
  Future<void> openSettings() async => openSettingsCount++;
}
