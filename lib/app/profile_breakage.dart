/// Why a saved profile cannot be run right now — and, because each case has
/// exactly one remedy, which remedy the home list offers on the row.
///
/// A sealed type rather than the line of text it used to be: the message and
/// the action have to agree, and a `String?` next to an enum would be two
/// fields to keep in step. The row carries the case, the page switches over
/// it, and a case with no remedy cannot be rendered by accident.
sealed class ProfileBreakage {
  const ProfileBreakage();

  /// The line shown in place of the tap summary, saying both what is wrong
  /// and what the button next to it will do.
  String get message;
}

/// The profile's peer has been revoked since it was saved: this host knows
/// the device by id and nothing else. The remedy is to pair with it again,
/// which the home list reaches through Devices.
final class ProfileDeviceUnpaired extends ProfileBreakage {
  const ProfileDeviceUnpaired();

  @override
  String get message =>
      'The device this profile syncs with is no longer paired. Pair with it '
      'again to run this profile.';
}

/// An entry's local root no longer passes the core's folder check — the
/// grant was withdrawn, or the folder moved. The remedy is to point that
/// entry at a folder this head can read and write, which the home list does
/// with the same chooser Run setup uses.
final class ProfileLocalRootUnusable extends ProfileBreakage {
  const ProfileLocalRootUnusable(this.entryIndex);

  /// Which of the profile's entries fails the check — the first one that
  /// does, and where the remedy's repick is aimed.
  final int entryIndex;

  @override
  String get message =>
      'The local folder is no longer accessible. Choose it again — or another '
      'folder — to run this profile.';
}
