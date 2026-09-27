/// Where `FileChooser.start` left the choice of a single file: done, given
/// up, or waiting on a browse of a folder. Which one a platform can reach is
/// decided by its picker (`FolderPicker.picksFilesNatively`), so a page
/// that switches on this never asks what platform it is on.
sealed class FileChoice {
  const FileChoice();
}

/// The platform's file dialog answered with [path], the file's own.
final class FileChosen extends FileChoice {
  const FileChosen(this.path);

  final String path;
}

/// The folder chooser answered with [root]; the file in it is chosen by
/// browsing its listing (`FileChooserPage`), which is also where a name not
/// there yet is typed.
final class FileBrowse extends FileChoice {
  const FileBrowse(this.root);

  final String root;
}

/// The user dismissed the dialog: nothing was chosen, nothing changes.
final class FileDismissed extends FileChoice {
  const FileDismissed();
}
