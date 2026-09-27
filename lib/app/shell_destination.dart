/// A top-level place the app shell navigates between: one entry on a wide
/// window's rail, one page pushed off the home on a compact one.
///
/// **One list for both layouts.** A wide window reaches every destination
/// in one click from the rail; a compact one reaches each through the page
/// it has always been pushed from ([compactParent]). The destination is the
/// same value either way, so resizing a window across the breakpoint keeps
/// where the user is — the layout only changes how it is drawn.
enum ShellDestination {
  /// The saved runs, the home (`ProfilesPage`).
  profiles,

  /// The paired device list, where every run is born (`DevicesPage`).
  devices,

  /// What this host shares and with whom (`SharedFoldersPage`).
  sharedFolders,

  /// Sync history: the archives and what they cost (`ArchivesPage`).
  archives,

  /// Answering paired devices (`ServePage`).
  serve,

  /// The installation's own settings (`SettingsPage`).
  settings,

  /// This installation's own identity (`ThisDevicePage`).
  thisDevice;

  /// The destination a compact window shows this one pushed over, or
  /// `null` for the home, which is under everything.
  ///
  /// Shared folders and This device sit under Devices on a phone because
  /// they answer the questions the device list raises — what each peer may
  /// reach, and who this device is to them. The rest are reached from the
  /// home's app bar: they belong to the installation, not to any one peer.
  ShellDestination? get compactParent => switch (this) {
    profiles => null,
    devices || archives || serve || settings => profiles,
    sharedFolders || thisDevice => devices,
  };
}
