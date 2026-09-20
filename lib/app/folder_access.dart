import 'dart:io';

import 'package:path/path.dart' as p;

/// Why [path] cannot be a replica root, or `null` when it can: it lists,
/// and one entry can be written and removed in it.
///
/// The probe is plain `dart:io`, which is exactly what `Scanner` and
/// `LocalAgent` scan and write a replica with, so a folder that passes it is
/// scannable by construction and a folder that fails it is refused before a
/// run — not judged by a permission API, because on Android the chooser's
/// grant covers the `content://` tree URI it returns and *not* the path that
/// URI converts to (see `RunSetupController`'s doc comment). One function,
/// two renderers: Run setup runs it over a folder the user has just picked,
/// and the profiles home runs it over the local root a saved profile names,
/// where a refusal is what renders the profile broken.
Future<String?> folderAccessRefusal(String path) async {
  final probe = File(p.join(path, '.dsync-access-probe'));
  try {
    await Directory(path).list(followLinks: false).take(1).toList();
    await probe.writeAsString('');
    await probe.delete();
    return null;
  } on FileSystemException catch (e) {
    return 'dsync cannot use $path: ${e.osError?.message ?? e.message}. '
        'Grant dsync access to all files, then choose it again.';
  }
}
