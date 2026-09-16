import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// The platform's folder chooser, and the OS grant that decides whether what
/// it hands back is a folder this head can actually use.
///
/// An interface because neither half can run in a test: both are platform
/// channels (the abstraction-at-the-border rule in `CLAUDE.md`). It is one
/// interface rather than two because the two calls are one story — a picked
/// folder that cannot be read is a grant problem, and the code that picks is
/// the code that has to ask — and because the platform decides both.
///
/// **It deliberately does not say whether a folder is usable.** That is what
/// `RunSetupController` probes with plain `dart:io`, because `dart:io` is
/// what `Scanner` and `LocalAgent` scan and write with: a folder that passes
/// the probe is scannable by construction, and a folder that fails it is not,
/// whatever any permission API reports. On Android the two are genuinely
/// separate facts — [pick] launches `ACTION_OPEN_DOCUMENT_TREE`, whose grant
/// covers the `content://` tree URI it returns, while the *path* that URI
/// converts to is openable only under All-files access ([requestAccess]) —
/// so asking the grant "may I?" and asking the filesystem "did it work?" are
/// two different questions and only the second one is load-bearing.
abstract interface class FolderPicker {
  /// The absolute path of the folder the user chose, or `null` if they
  /// dismissed the chooser. May throw whatever the platform channel throws.
  Future<String?> pick();

  /// Asks for the grant that makes a picked path readable and writable
  /// through `dart:io`, returning what the platform reports afterwards.
  /// Advisory only — see the class doc comment.
  Future<bool> requestAccess();

  /// Opens the OS settings page where that grant can be given, for the user
  /// who refused it and changed their mind.
  Future<void> openSettings();
}

/// [FolderPicker] over `file_picker` and `permission_handler` — the one
/// place this head touches either plugin.
final class PlatformFolderPicker implements FolderPicker {
  const PlatformFolderPicker();

  @override
  Future<String?> pick() => FilePicker.getDirectoryPath();

  @override
  Future<bool> requestAccess() async {
    // API 30+: the Settings-screen grant, which is the one that matters for
    // a path outside the app's own container. Requested first because it
    // subsumes the legacy one where it exists.
    if (await Permission.manageExternalStorage.request().isGranted) return true;
    // API <=29, where shared storage is reached with the old runtime
    // permission and `manageExternalStorage` does not exist.
    return Permission.storage.request().isGranted;
  }

  @override
  Future<void> openSettings() => openAppSettings();
}
