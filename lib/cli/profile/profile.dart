import 'package:dsync/dsync_core/models/location.dart';
import 'package:dsync/dsync_core/models/rule_set.dart';
import 'package:dsync/dsync_core/models/ssh_access.dart';

/// A parsed profile (SPEC §12): the two replicas a sync run pairs, the rules
/// that apply to it, and its optional size-warning and job-count options.
///
/// Built only by `loadProfile` (`profile_loader.dart`) — a plain value
/// object with no I/O of its own and no defaulting. [warnSizeBytes] and
/// [jobs] stay nullable so a caller merging this with command-line flags
/// (task 603ea7) can tell "the profile leaves this unset" from "the profile
/// sets this to a default", and let a flag win either way.
///
/// [a] and [b] are exactly the replicas named `a` and `b` in the profile's
/// `[replicas]` table. Which one is written first in the file has no effect
/// on which is which — a profile's `a` may be the remote replica. The
/// "local first" convention for an ad-hoc `<locA> <locB>` pair (SPEC §11.1)
/// is a rule for that command only and does not apply here.
class Profile {
  /// The profile's name — its filename under `profiles/` without the
  /// `.toml` extension — which per SPEC §8.3 doubles as its id in archive
  /// and lock file names.
  final String name;

  /// Replica `a`, as named in `[replicas]`.
  final Location a;

  /// Replica `b`, as named in `[replicas]`.
  final Location b;

  /// The `[rules]` table (SPEC §9), or an empty [RuleSet] when the profile
  /// has no `[rules]` table.
  final RuleSet rules;

  /// `[options] warn_size_bytes` (SPEC §10), or `null` when the profile
  /// does not set it.
  final int? warnSizeBytes;

  /// `[options] jobs`, or `null` when the profile does not set it.
  final int? jobs;

  /// `[ssh.a]` (SPEC §4.2, §12): how the ssh transport reaches replica [a]
  /// when it is remote, or the default access when the profile says nothing.
  /// Ignored for a replica that runs in-process (SPEC §4.1) — a profile may
  /// carry one for a side that is local on this machine and remote from the
  /// other end of the pair.
  final SshAccess sshA;

  /// `[ssh.b]` — see [sshA].
  final SshAccess sshB;

  const Profile({
    required this.name,
    required this.a,
    required this.b,
    required this.rules,
    this.warnSizeBytes,
    this.jobs,
    this.sshA = const SshAccess(),
    this.sshB = const SshAccess(),
  });
}
