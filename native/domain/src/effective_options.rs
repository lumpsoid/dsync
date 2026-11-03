//! The options a run actually uses: flags over profile over defaults.

use crate::entry::Entry;
use crate::entry_id::{CanonicalSide, EntryId};
use crate::host_facts::HostFacts;
use crate::jobs::Jobs;
use crate::location::Locality;
use crate::mass_delete::MassDeletePolicy;
use crate::options_error::OptionsError;
use crate::profile::Profile;
use crate::rel_path::RelPath;
use crate::replica_location::ReplicaLocation;
use crate::root_kind::RootKind;
use crate::rule_set::RuleSet;
use crate::run_flags::RunFlags;
use crate::side::Side;
use crate::ssh_access::SshAccess;

/// One run's replicas, rules and knobs, merged: an ad-hoc pair, or one
/// entry of a profile. `warn_size_bytes` stays `None` when neither a
/// flag, the profile nor the head's default sets it; `jobs` when neither a
/// flag nor the profile does, and the caller's default (`Tuning`) applies
/// then.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct EffectiveOptions {
    a: ReplicaLocation,
    b: ReplicaLocation,
    kind: RootKind,
    as_path: Option<RelPath>,
    pub rules: RuleSet,
    pub warn_size_bytes: Option<u64>,
    pub jobs: Option<Jobs>,
    /// `--allow-mass-delete`: SPEC §10's delete guard reports, but does not
    /// ask. A flag only; no profile sets it.
    pub allow_mass_delete: bool,
    /// `--allow-mass-overwrite`: SPEC §10's overwrite guard reports, but
    /// does not ask. A flag only; no profile sets it.
    pub allow_mass_overwrite: bool,
    /// When SPEC §10's delete guard trips: the head's thresholds, or the
    /// default. No profile sets it.
    pub mass_delete: MassDeletePolicy,
    pub entry_id: EntryId,
    ssh_a: SshAccess,
    ssh_b: SshAccess,
}

impl EffectiveOptions {
    /// One entry of a named profile under this run's flags, its two sides
    /// already canonicalized and checked by [`Profile::options`]. The
    /// entry's a/b order is kept as written, even remote-first. `--ignore`
    /// and `--ssh-option` add to the profile's; `--warn-size`, `--jobs` and
    /// `--remote-dsync` override it. The head's default warn size applies
    /// only when neither the flag nor the profile sets one. Each side keeps its own
    /// `[ssh.a]`/`[ssh.b]`.
    pub(crate) fn for_entry(
        profile: &Profile,
        entry: &Entry,
        (canonical_a, canonical_b): (&CanonicalSide, &CanonicalSide),
        flags: &RunFlags,
    ) -> EffectiveOptions {
        let ssh = |side| {
            profile
                .ssh(side)
                .with_flags(&flags.ssh_options, flags.remote_dsync.clone())
        };
        EffectiveOptions {
            a: entry.replica(Side::A).clone(),
            b: entry.replica(Side::B).clone(),
            kind: entry.kind(),
            as_path: entry.as_path(),
            rules: profile.rules().merged_with(&flag_rules(flags)),
            warn_size_bytes: flags
                .warn_size_bytes
                .or(profile.warn_size_bytes())
                .or(flags.default_warn_size_bytes),
            jobs: flags.jobs.or(profile.jobs()),
            allow_mass_delete: flags.allow_mass_delete,
            allow_mass_overwrite: flags.allow_mass_overwrite,
            mass_delete: flags.mass_delete,
            entry_id: EntryId::for_entry(entry.kind(), canonical_a, canonical_b),
            ssh_a: ssh(Side::A),
            ssh_b: ssh(Side::B),
        }
    }

    /// Two typed locations. Side A is the in-process one when exactly one
    /// is; otherwise the canonically smaller, so the same pair typed in
    /// either order is one pair with one A. `local_addresses` are this
    /// machine's names, fetched only when
    /// [`crate::AdHocTarget::consults_local_addresses`] says they matter.
    /// Both sides get the flags' ssh access: there is no profile to differ
    /// from.
    pub fn for_ad_hoc(
        first: ReplicaLocation,
        second: ReplicaLocation,
        flags: &RunFlags,
        facts: &HostFacts,
        local_addresses: &[String],
    ) -> Result<EffectiveOptions, OptionsError> {
        let canonical_first = CanonicalSide::of(&first, facts)?;
        let canonical_second = CanonicalSide::of(&second, facts)?;
        if canonical_first.overlaps(&canonical_second) {
            return Err(OptionsError::AdHocOverlap {
                first: canonical_first.to_string(),
                second: canonical_second.to_string(),
            });
        }
        let locality_first = first.to_location().locality(local_addresses);
        let locality_second = second.to_location().locality(local_addresses);
        let first_is_a = if locality_first == locality_second {
            canonical_first.to_string() <= canonical_second.to_string()
        } else {
            locality_first == Locality::InProcess
        };
        let (a, b) = if first_is_a {
            (first, second)
        } else {
            (second, first)
        };
        let access =
            SshAccess::default().with_flags(&flags.ssh_options, flags.remote_dsync.clone());
        Ok(EffectiveOptions {
            a,
            b,
            kind: RootKind::Folder,
            as_path: None,
            rules: flag_rules(flags),
            warn_size_bytes: flags.warn_size_bytes.or(flags.default_warn_size_bytes),
            jobs: flags.jobs,
            allow_mass_delete: flags.allow_mass_delete,
            allow_mass_overwrite: flags.allow_mass_overwrite,
            mass_delete: flags.mass_delete,
            entry_id: EntryId::for_pair(&canonical_first, &canonical_second),
            ssh_a: access.clone(),
            ssh_b: access,
        })
    }

    pub fn replica(&self, side: Side) -> &ReplicaLocation {
        match side {
            Side::A => &self.a,
            Side::B => &self.b,
        }
    }

    /// Whether the entry pairs two folders or two files.
    pub fn kind(&self) -> RootKind {
        self.kind
    }

    /// For a file entry, the name its file syncs under; `None` for a
    /// folder.
    pub fn as_path(&self) -> Option<&RelPath> {
        self.as_path.as_ref()
    }

    pub fn ssh(&self, side: Side) -> &SshAccess {
        match side {
            Side::A => &self.ssh_a,
            Side::B => &self.ssh_b,
        }
    }
}

fn flag_rules(flags: &RunFlags) -> RuleSet {
    RuleSet::new(flags.ignore.clone(), vec![])
}

#[cfg(test)]
mod tests;
