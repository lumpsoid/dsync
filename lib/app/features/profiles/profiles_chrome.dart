import 'package:flutter/widgets.dart';

/// Who draws the home page's ways to the other destinations: the page's own
/// app bar and "New run" button, or the app shell around it.
///
/// A sum type rather than nullable callbacks so the page draws all of its
/// navigation chrome or none of it: there is no layout in which Settings is
/// in the app bar while Sync history is on the rail, and a set of nullables
/// would let a caller build one. The page never works out which case
/// applies — the shell decides from the window, once, and says so here.
sealed class ProfilesChrome {
  const ProfilesChrome();
}

/// The page is the whole window (a phone, a narrow desktop window): its
/// app bar carries Serve, Sync history, Settings and Devices, and a "New
/// run" button floats over the list.
final class ProfilesOwnChrome extends ProfilesChrome {
  const ProfilesOwnChrome({
    required this.onOpenArchives,
    required this.onOpenSettings,
    required this.onOpenServe,
  });

  /// Opens the Sync history page, where the archives are listed with what
  /// they cost and can be deleted. From the app bar only: it is maintenance,
  /// not part of setting up or making a run.
  final VoidCallback onOpenArchives;

  /// Opens the Settings page. From the app bar of the home page, because
  /// settings belong to the installation rather than to any one device,
  /// profile or run — this is the only screen every route starts from.
  final VoidCallback onOpenSettings;

  /// Opens the Serve page, where this device starts answering paired
  /// devices (SPEC §4.4). From the app bar of the home page because it is
  /// an activity the user starts — their hands are on the device that will
  /// serve — rather than a subsection of managing any one peer.
  final VoidCallback onOpenServe;
}

/// The shell draws the destinations and "New run" beside the page, so the
/// app bar keeps only what acts on this page itself.
final class ProfilesShellChrome extends ProfilesChrome {
  const ProfilesShellChrome();
}
