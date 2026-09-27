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

  /// Whether this stands in for a desktop, whose file dialog answers with a
  /// real path, rather than a phone, where a file is chosen by browsing a
  /// picked folder.
  @override
  bool picksFilesNatively = false;

  /// What the file dialog returns; `null` is the user dismissing it.
  String? Function() onPickFile = () => null;

  int pickCount = 0;
  int pickFileCount = 0;
  int requestAccessCount = 0;
  int openSettingsCount = 0;

  @override
  Future<String?> pick() async {
    pickCount++;
    return onPick();
  }

  /// Refuses where [picksFilesNatively] is false, the way the real picker
  /// does, so a phone-path test cannot reach the file dialog unnoticed.
  @override
  Future<String?> pickFile() async {
    if (!picksFilesNatively) throw UnsupportedError('no native file dialog');
    pickFileCount++;
    return onPickFile();
  }

  @override
  Future<bool> requestAccess() {
    requestAccessCount++;
    return onRequestAccess();
  }

  @override
  Future<void> openSettings() async => openSettingsCount++;
}
