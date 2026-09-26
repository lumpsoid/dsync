//! The options a run actually uses: flags over profile over defaults.

use crate::entry_id::{CanonicalSide, EntryId};
use crate::host_facts::HostFacts;
use crate::jobs::Jobs;
use crate::location::Locality;
use crate::options_error::OptionsError;
use crate::profile::{Profile, ProfileName};
use crate::replica_location::ReplicaLocation;
use crate::rule_set::RuleSet;
use crate::run_flags::RunFlags;
use crate::side::Side;
use crate::ssh_access::SshAccess;

/// One run's replicas, rules and knobs, merged. `warn_size_bytes` and
/// `jobs` stay `None` when neither a flag nor the profile sets them; the
/// caller's default (`Tuning`) applies then.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct EffectiveOptions {
    a: ReplicaLocation,
    b: ReplicaLocation,
    pub rules: RuleSet,
    pub warn_size_bytes: Option<u64>,
    pub jobs: Option<Jobs>,
    /// `--allow-mass-delete`: SPEC §10's delete guard reports, but does not
    /// ask. A flag only; no profile sets it.
    pub allow_mass_delete: bool,
    pub entry_id: EntryId,
    ssh_a: SshAccess,
    ssh_b: SshAccess,
}

impl EffectiveOptions {
    /// A named profile under this run's flags. The profile's a/b order is
    /// kept as written, even remote-first. `--ignore` and `--ssh-option`
    /// add to the profile's; `--warn-size`, `--jobs` and `--remote-dsync`
    /// override it. Each side keeps its own `[ssh.a]`/`[ssh.b]`.
    pub fn for_profile(
        name: &ProfileName,
        profile: &Profile,
        flags: &RunFlags,
        facts: &HostFacts,
    ) -> Result<EffectiveOptions, OptionsError> {
        let a = profile.replica(Side::A).clone();
        let b = profile.replica(Side::B).clone();
        let (canonical_a, canonical_b) = canonical_pair(&a, &b, facts)?;
        if canonical_a == canonical_b {
            return Err(OptionsError::ProfileSameLocation {
                profile: name.to_string(),
                canonical: canonical_a.to_string(),
            });
        }
        let ssh = |side| {
            profile
                .ssh(side)
                .with_flags(&flags.ssh_options, flags.remote_dsync.clone())
        };
        Ok(EffectiveOptions {
            rules: profile.rules().merged_with(&flag_rules(flags)),
            warn_size_bytes: flags.warn_size_bytes.or(profile.warn_size_bytes()),
            jobs: flags.jobs.or(profile.jobs()),
            allow_mass_delete: flags.allow_mass_delete,
            entry_id: EntryId::for_pair(&canonical_a, &canonical_b),
            ssh_a: ssh(Side::A),
            ssh_b: ssh(Side::B),
            a,
            b,
        })
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
        let (canonical_first, canonical_second) = canonical_pair(&first, &second, facts)?;
        if canonical_first == canonical_second {
            return Err(OptionsError::AdHocSameLocation {
                canonical: canonical_first.to_string(),
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
            rules: flag_rules(flags),
            warn_size_bytes: flags.warn_size_bytes,
            jobs: flags.jobs,
            allow_mass_delete: flags.allow_mass_delete,
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

    pub fn ssh(&self, side: Side) -> &SshAccess {
        match side {
            Side::A => &self.ssh_a,
            Side::B => &self.ssh_b,
        }
    }
}

fn canonical_pair(
    a: &ReplicaLocation,
    b: &ReplicaLocation,
    facts: &HostFacts,
) -> Result<(CanonicalSide, CanonicalSide), OptionsError> {
    Ok((CanonicalSide::of(a, facts)?, CanonicalSide::of(b, facts)?))
}

fn flag_rules(flags: &RunFlags) -> RuleSet {
    RuleSet::new(flags.ignore.clone(), vec![])
}

#[cfg(test)]
mod tests;
