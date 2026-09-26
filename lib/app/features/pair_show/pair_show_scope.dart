import 'dart:io';

import '../../app_scope.dart';
import 'pair_show_controller.dart';

/// The cell for [PairShowController]; see the scope contract in
/// `app_scope.dart`. The Show-this-device's-code page takes
/// `pairShowScope.create()`, not the cached `controller`, and disposes what
/// it got: the controller owns an open pairing window, and a second page
/// sharing one would mean two pages over one endpoint.
///
/// The default factory names how the address the core binds is obtained,
/// which is this head's equivalent of `dsync pair show --bind` (task
/// 2b26ac).
///
/// **The address is read, not stated.** It used to be
/// `InternetAddress.anyIPv4` written here, because the head had no settings
/// surface to opt out of it through; it now has one, so the value comes
/// from the Settings page's Network section by way of `AppSettingsStore` —
/// still `0.0.0.0` by default, the same default the CLI's flag carries.
/// Read per window rather than once, because the store's contract is fresh
/// reads: a user who changes the address and then shows a code gets the
/// address they just set, not the one this process started with.
final class PairShowScope extends Scope<PairShowController> {
  PairShowScope()
    : super(
        () => PairShowController(
          appScope.controller,
          bindAddress: storedBindAddress,
        ),
      );
}

/// The stored bind address, freshly read. Throws
/// `AppSettingsStoreException` when the settings file cannot be read —
/// `PairShowController.show` renders that as the window's refusal rather
/// than binding the defaults on a file it cannot trust.
Future<InternetAddress> storedBindAddress() async =>
    (await (await appScope.controller.settings).load()).bindAddress;

/// The single Show-this-device's-code scope.
final pairShowScope = PairShowScope();
