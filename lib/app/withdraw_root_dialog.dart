import 'package:flutter/material.dart';

import 'destructive_confirm_dialog.dart';

/// The confirmation before a folder is withdrawn from a device — the undo
/// of a grant (SPEC §4.4's second step), asked for with the same weight as
/// the revoke of a whole pairing.
///
/// It exists because withdrawing used to be one tap on a small icon in a
/// list of paths that share every character but their last few: the row the
/// finger lands on and the row the user meant are indistinguishable at a
/// glance, and nothing said which folder had just stopped being served.
///
/// The copy carries what is actually true of a withdrawal, which is not
/// obvious: it is local and one-sided like every other write on this host,
/// so [deviceName] is told nothing and goes on believing it may ask. What
/// changes is the answer it gets — the next `hello` naming this root is
/// refused. Nothing on disk moves, which is the other half of what a user
/// hesitating over this button is afraid of.
///
/// Lives in `app/` beside the other cross-feature pieces because both the
/// device page and the Shared folders page withdraw a grant, and neither
/// owns this more than the other: two dialogs saying almost the same thing
/// about the same write is how a user learns that one of the two is lying.
///
/// Pops `true` to withdraw and `false` to keep sharing; a dismissal pops
/// nothing, and every caller treats that as "keep sharing". Asked through
/// [DestructiveConfirmDialog], so "Keep sharing" has the focus and Enter
/// withdraws nothing.
class WithdrawRootDialog extends StatelessWidget {
  const WithdrawRootDialog({
    super.key,
    required this.rootLabel,
    required this.deviceName,
  });

  /// The folder as the row above showed it — the elided label, not the
  /// stored path, so the dialog names the same thing the user tapped.
  final String rootLabel;

  /// This host's own name for the device losing the grant.
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    return DestructiveConfirmDialog(
      title: 'Stop sharing $rootLabel?',
      message:
          '$deviceName will no longer be allowed to reach this folder. The '
          'next time it asks for it, this device refuses.\n\n'
          '$deviceName is not told, and nothing in the folder is moved or '
          'deleted. Files it has already synced stay where they are on both '
          'devices.',
      cancelLabel: 'Keep sharing',
      confirmLabel: 'Stop sharing',
      cancelKey: const Key('withdraw-root-cancel'),
      confirmKey: const Key('withdraw-root-confirm'),
    );
  }
}
