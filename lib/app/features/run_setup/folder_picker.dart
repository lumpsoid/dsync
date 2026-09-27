import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// The platform's folder chooser, its file dialog where that hands back a
/// real path, and the OS grant that decides whether what they hand back is a
/// folder this head can actually use.
///
/// An interface because none of it can run in a test: all of it is platform
/// channels (the abstraction-at-the-border rule in `CLAUDE.md`). It is one
/// interface rather than two because the two calls are one story — a picked
/// folder that cannot be read is a grant problem, and the code that picks is
/// the code that has to ask — and because the platform decides both. The
/// file dialog sits here for the same reason: whether it answers with a
/// real path is decided by the same platform fact, at the same edge.
///
/// **It deliberately does not say whether a folder is usable.** That is what
/// `RunSetupController` asks the core to check — list the folder, write and
/// remove one entry, exactly what a scan and a write do — so a folder that
/// passes is usable by construction, and a folder that fails it is not,
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

  /// Whether [pickFile] is this platform's way to choose a single file: a
  /// native file dialog that answers with the file's own path. True on
  /// Linux, macOS and Windows. False on Android and iOS, where the file
  /// dialog answers with a copy of the file in the app's cache (`file_picker`
  /// 13.1.0 `FileUtils.kt:741-760`) — a root built from it would sync the
  /// copy — so a file is chosen there by browsing a [pick]ed folder instead
  /// (`FileChooser`).
  bool get picksFilesNatively;

  /// The absolute path of the file the user chose in the platform's file
  /// dialog, or `null` if they dismissed it. Only where [picksFilesNatively];
  /// elsewhere it throws [UnsupportedError] rather than hand back a path
  /// that is not the file's. May throw whatever the platform channel throws.
  Future<String?> pickFile();

  /// Whether this platform has that grant at all — a Settings page where
  /// the user can give it. Where it does not, [requestAccess] and
  /// [openSettings] are inert, and a picked path the core refuses stays
  /// refused until the user changes something outside this app.
  bool get asksForFileAccess;
}

/// [FolderPicker] over `file_picker` and `permission_handler` — the one
/// place this head touches either plugin.
///
/// [asksForFileAccess] is what separates the two kinds of host this head now
/// runs on, and it is a fact about the *platform*, not a preference. On
/// Android and iOS a folder outside the app's own container is reachable
/// through `dart:io` only under a grant the user gives on a Settings screen
/// (SPEC §3, §16), so there is something to ask for and somewhere to send
/// them. On Linux, macOS and Windows there is not: the process runs as the
/// user, a folder it cannot open is one the *filesystem* refused, and
/// `permission_handler` has no implementation there at all — calling it
/// would throw a `MissingPluginException` out of the chooser rather than
/// answer anything. So on desktop both grant methods are inert, and a
/// refusal from the core's folder check stands as the final answer, which is
/// exactly what it is.
final class PlatformFolderPicker implements FolderPicker {
  const PlatformFolderPicker({
    required this.asksForFileAccess,
    required this.picksFilesNatively,
  });

  /// Reads the platform at this one edge and hands a plain value down, the
  /// way `supportDirForThisDevice` does. Production only;
  /// a test constructs the case it is about with the plain constructor.
  factory PlatformFolderPicker.forThisHost() {
    final phone = Platform.isAndroid || Platform.isIOS;
    return PlatformFolderPicker(
      asksForFileAccess: phone,
      picksFilesNatively: !phone,
    );
  }

  /// Whether this platform has a file-access grant to ask for — see the
  /// class doc comment.
  @override
  final bool asksForFileAccess;

  /// Whether the file dialog hands back the file's own path — see
  /// [FolderPicker.picksFilesNatively].
  @override
  final bool picksFilesNatively;

  @override
  Future<String?> pick() => FilePicker.getDirectoryPath();

  @override
  Future<String?> pickFile() async {
    if (!picksFilesNatively) {
      throw UnsupportedError('This platform picks a file by browsing a folder');
    }
    return (await FilePicker.pickFile())?.path;
  }

  @override
  Future<bool> requestAccess() async {
    if (!asksForFileAccess) return false;
    // API 30+: the Settings-screen grant, which is the one that matters for
    // a path outside the app's own container. Requested first because it
    // subsumes the legacy one where it exists.
    if (await Permission.manageExternalStorage.request().isGranted) return true;
    // API <=29, where shared storage is reached with the old runtime
    // permission and `manageExternalStorage` does not exist.
    return Permission.storage.request().isGranted;
  }

  @override
  Future<void> openSettings() async {
    if (!asksForFileAccess) return;
    await openAppSettings();
  }
}
