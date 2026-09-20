/// One out-of-band check a user has made on a pairing (SPEC §4.4): they read
/// the device id this host pinned for a peer, compared it against the id that
/// peer shows on its own screen, and said the two matched.
///
/// **Not a security decision this host makes — a record of one the user
/// made.** Nothing in the protocol consults it: a peer is trusted because its
/// key is pinned, and a peer whose key does not match is refused at the
/// handshake whether or not anything here says "verified". What this adds is
/// the one thing pinning cannot establish on its own — that the key pinned at
/// pairing time is the key the *intended* device holds, rather than one
/// relayed by a middle that saw the pairing payload. That question can only be
/// answered by a human comparing two screens, so this is what that human's
/// answer is written down as.
///
/// **[deviceId] is stored, not assumed.** A verification is about a specific
/// key, and the whole point of it is to stop meaning "verified" the moment
/// that key changes — a pairing thrown away and redone against a different
/// device must not inherit the confirmation its predecessor earned. Storing a
/// bare `bool` beside the certificate would inherit it silently; storing the
/// id that was compared makes the mismatch visible to anyone holding both.
library;

/// See the library doc comment. Immutable, and parsed at construction: an
/// empty [deviceId] could never match a real one, so it is refused here
/// rather than lingering as a verification that can never apply.
class DeviceVerification {
  /// The device id the user compared — SPEC §4.4's grouped hex, the same
  /// string `PairedDevice.deviceId` renders and the peer shows on its own
  /// This-device page.
  final String deviceId;

  /// When the comparison was made, in this host's own clock. Displayed, and
  /// nothing more: it never expires. Nothing about a pinned key changes on
  /// its own over time, so a verification that decayed into "check me again"
  /// would be asking for a ritual with no question behind it — and teaching
  /// the user to click through the one prompt that does matter.
  final DateTime at;

  DeviceVerification({required this.deviceId, required this.at}) {
    if (deviceId.trim().isEmpty) {
      throw const FormatException('Empty verified device id');
    }
  }
}
