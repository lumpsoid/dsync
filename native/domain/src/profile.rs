//! A profile (SPEC §12), parsed from its TOML text.

use std::fmt;
use std::str::FromStr;
use std::sync::LazyLock;

use toml::{Table, Value};

use crate::device_id::DeviceId;
use crate::glob::Glob;
use crate::host_facts::HostFacts;
use crate::jobs::Jobs;
use crate::location::{ExpandError, Location};
use crate::platform::Platform;
use crate::profile_id::{CanonicalSide, ProfileId};
use crate::replica_location::{ReplicaLocation, ReplicaLocationError};
use crate::rule_set::RuleSet;
use crate::side::Side;
use crate::ssh_access::{SshAccess, SshCommand, SshOption};

#[cfg(test)]
mod tests;

/// A profile: the two replicas a run pairs, its rules and options, and
/// how ssh reaches each side.
///
/// The schema is SPEC §12's, extended for the app head (plan D7): a
/// `peer://` replica carries the device id its name resolved to, as
/// `[replicas] a_device_id` / `b_device_id`, so a renamed peer does not
/// break the profile. A device id is required for a `peer://` side and
/// refused for any other. Every table and key is optional except
/// `[replicas] a` and `b`; an unknown one is an error - a misspelled key
/// silently ignored is how a profile quietly stops ignoring `**/.git`.
///
/// `warn_size_bytes` and `jobs` stay `None` when unset, so a flag can be
/// told apart from a profile default when options are merged.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Profile {
    a: ReplicaLocation,
    b: ReplicaLocation,
    rules: RuleSet,
    warn_size_bytes: Option<u64>,
    jobs: Option<Jobs>,
    ssh_a: SshAccess,
    ssh_b: SshAccess,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProfileError {
    #[error("not valid TOML: {0}")]
    Toml(String),
    #[error("unknown key: {0}")]
    UnknownKey(String),
    #[error("missing replica \"{0}\" in [replicas]")]
    MissingReplica(Side),
    #[error(
        "replicas.{side} is a peer:// location; set replicas.{side}_device_id to its device id"
    )]
    MissingDeviceId { side: Side },
    #[error("replicas.{side}_device_id is set, but replicas.{side} is not a peer:// location")]
    UnexpectedDeviceId { side: Side },
    #[error("invalid {key}: {reason}")]
    InvalidValue { key: String, reason: String },
}

const TABLES: &[&str] = &["replicas", "rules", "options", "ssh"];
const REPLICA_KEYS: &[&str] = &["a", "b", "a_device_id", "b_device_id"];
const RULE_KEYS: &[&str] = &["ignore", "follow"];
const OPTION_KEYS: &[&str] = &["warn_size_bytes", "jobs"];
const SSH_SIDES: &[&str] = &["a", "b"];
const SSH_KEYS: &[&str] = &["options", "command"];

impl Profile {
    /// A profile of `a` and `b` built from values, as the head creates one
    /// (plan OQ1): no rules, no options, default ssh access until the
    /// `with_` calls below add them. Both locations are already typed, so
    /// nothing here can fail.
    pub fn new(a: ReplicaLocation, b: ReplicaLocation) -> Profile {
        Profile {
            a,
            b,
            rules: RuleSet::default(),
            warn_size_bytes: None,
            jobs: None,
            ssh_a: SshAccess::default(),
            ssh_b: SshAccess::default(),
        }
    }

    pub fn with_rules(self, rules: RuleSet) -> Profile {
        Profile { rules, ..self }
    }

    pub fn with_jobs(self, jobs: Jobs) -> Profile {
        Profile {
            jobs: Some(jobs),
            ..self
        }
    }

    /// Parses a profile's TOML text; locations by `platform`'s rules.
    pub fn parse(text: &str, platform: Platform) -> Result<Profile, ProfileError> {
        let root: Table = text
            .parse()
            .map_err(|e: toml::de::Error| ProfileError::Toml(e.message().to_owned()))?;
        check_keys(&root, TABLES, "")?;

        let replicas = table(&root, "replicas", "")?;
        check_keys(replicas, REPLICA_KEYS, "replicas.")?;
        let a = replica(replicas, Side::A, platform)?;
        let b = replica(replicas, Side::B, platform)?;

        let rules = table(&root, "rules", "")?;
        check_keys(rules, RULE_KEYS, "rules.")?;
        let rules = RuleSet::new(globs(rules, "ignore")?, globs(rules, "follow")?);

        let options = table(&root, "options", "")?;
        check_keys(options, OPTION_KEYS, "options.")?;
        let warn_size_bytes = integer(options, "options.", "warn_size_bytes")?
            .map(|bytes| {
                u64::try_from(bytes)
                    .map_err(|_| invalid("options.warn_size_bytes", "it is negative"))
            })
            .transpose()?;
        let jobs = integer(options, "options.", "jobs")?
            .map(|count| Jobs::new(count).map_err(|e| invalid("options.jobs", e)))
            .transpose()?;

        let ssh = table(&root, "ssh", "")?;
        check_keys(ssh, SSH_SIDES, "ssh.")?;

        Ok(Profile {
            a,
            b,
            rules,
            warn_size_bytes,
            jobs,
            ssh_a: ssh_access(ssh, Side::A)?,
            ssh_b: ssh_access(ssh, Side::B)?,
        })
    }

    pub fn replica(&self, side: Side) -> &ReplicaLocation {
        match side {
            Side::A => &self.a,
            Side::B => &self.b,
        }
    }

    pub fn rules(&self) -> &RuleSet {
        &self.rules
    }

    pub fn warn_size_bytes(&self) -> Option<u64> {
        self.warn_size_bytes
    }

    pub fn jobs(&self) -> Option<Jobs> {
        self.jobs
    }

    /// How ssh reaches `side` when it is remote; ignored for a side that
    /// runs in-process (SPEC §12).
    pub fn ssh(&self, side: Side) -> &SshAccess {
        match side {
            Side::A => &self.ssh_a,
            Side::B => &self.ssh_b,
        }
    }

    /// This profile as TOML text that [`Profile::parse`] reads back to an
    /// equal profile. Optional tables and keys at their defaults are left
    /// out, so a profile written by the store reads like one written by
    /// hand; locations are spelled as typed, nothing expanded.
    pub fn to_toml(&self) -> String {
        let mut replicas = Table::new();
        for side in Side::BOTH {
            let replica = self.replica(side);
            replicas.insert(side.key().to_owned(), replica.to_string().into());
            if let Some(device) = replica.peer_device() {
                replicas.insert(format!("{side}_device_id"), device.to_string().into());
            }
        }
        let mut root = Table::new();
        root.insert("replicas".to_owned(), replicas.into());

        let mut rules = Table::new();
        for (key, globs) in [
            ("ignore", self.rules.ignore()),
            ("follow", self.rules.follow()),
        ] {
            if !globs.is_empty() {
                rules.insert(key.to_owned(), words(globs.iter().map(Glob::as_str)));
            }
        }
        insert_unless_empty(&mut root, "rules", rules);

        let mut options = Table::new();
        if let Some(bytes) = self.warn_size_bytes {
            // Parsed from a TOML integer, so it always fits back into one.
            options.insert(
                "warn_size_bytes".to_owned(),
                i64::try_from(bytes).unwrap_or(i64::MAX).into(),
            );
        }
        if let Some(jobs) = self.jobs {
            options.insert(
                "jobs".to_owned(),
                i64::try_from(jobs.get()).unwrap_or(i64::MAX).into(),
            );
        }
        insert_unless_empty(&mut root, "options", options);

        let mut ssh = Table::new();
        for side in Side::BOTH {
            let access = self.ssh(side);
            let mut table = Table::new();
            if !access.options().is_empty() {
                table.insert(
                    "options".to_owned(),
                    words(access.options().iter().map(SshOption::as_str)),
                );
            }
            if access.command() != &SshCommand::default() {
                table.insert("command".to_owned(), access.command().to_string().into());
            }
            insert_unless_empty(&mut ssh, side.key(), table);
        }
        insert_unless_empty(&mut root, "ssh", ssh);

        root.to_string()
    }

    /// The id this profile's archive and state are named by: the same one
    /// an ad-hoc run over the same pair derives (plan OQ6).
    pub fn id(&self, facts: &HostFacts) -> Result<ProfileId, ExpandError> {
        Ok(ProfileId::for_pair(
            &CanonicalSide::of(&self.a, facts)?,
            &CanonicalSide::of(&self.b, facts)?,
        ))
    }
}

fn invalid(key: &str, reason: impl fmt::Display) -> ProfileError {
    ProfileError::InvalidValue {
        key: key.to_owned(),
        reason: reason.to_string(),
    }
}

fn words<'a>(items: impl Iterator<Item = &'a str>) -> Value {
    Value::Array(items.map(Value::from).collect())
}

fn insert_unless_empty(parent: &mut Table, key: &str, table: Table) {
    if !table.is_empty() {
        parent.insert(key.to_owned(), table.into());
    }
}

fn check_keys(table: &Table, known: &[&str], prefix: &str) -> Result<(), ProfileError> {
    match table.keys().find(|key| !known.contains(&key.as_str())) {
        Some(key) => Err(ProfileError::UnknownKey(format!("{prefix}{key}"))),
        None => Ok(()),
    }
}

static EMPTY: LazyLock<Table> = LazyLock::new(Table::new);

/// The sub-table at `key`, or an empty one when absent.
fn table<'a>(parent: &'a Table, key: &str, prefix: &str) -> Result<&'a Table, ProfileError> {
    match parent.get(key) {
        None => Ok(&EMPTY),
        Some(Value::Table(table)) => Ok(table),
        Some(_) => Err(invalid(&format!("{prefix}{key}"), "expected a table")),
    }
}

fn string<'a>(table: &'a Table, prefix: &str, key: &str) -> Result<Option<&'a str>, ProfileError> {
    match table.get(key) {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text)),
        Some(_) => Err(invalid(&format!("{prefix}{key}"), "expected a string")),
    }
}

fn integer(table: &Table, prefix: &str, key: &str) -> Result<Option<i64>, ProfileError> {
    match table.get(key) {
        None => Ok(None),
        Some(Value::Integer(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(&format!("{prefix}{key}"), "expected an integer")),
    }
}

fn strings<'a>(table: &'a Table, prefix: &str, key: &str) -> Result<Vec<&'a str>, ProfileError> {
    let expected = || invalid(&format!("{prefix}{key}"), "expected an array of strings");
    match table.get(key) {
        None => Ok(vec![]),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| item.as_str().ok_or_else(expected))
            .collect(),
        Some(_) => Err(expected()),
    }
}

/// `replicas.<side>`, with its device id when `peer://`. Missing and
/// empty read the same: there is no replica to sync.
fn replica(
    replicas: &Table,
    side: Side,
    platform: Platform,
) -> Result<ReplicaLocation, ProfileError> {
    let raw = match string(replicas, "replicas.", side.key())? {
        Some(raw) if !raw.is_empty() => raw,
        _ => return Err(ProfileError::MissingReplica(side)),
    };
    let location =
        Location::parse(raw, platform).map_err(|e| invalid(&format!("replicas.{side}"), e))?;
    let device_key = format!("{side}_device_id");
    let device = string(replicas, "replicas.", &device_key)?
        .map(|text| {
            DeviceId::from_str(text).map_err(|e| invalid(&format!("replicas.{device_key}"), e))
        })
        .transpose()?;
    ReplicaLocation::new(location, device).map_err(|e| match e {
        ReplicaLocationError::MissingDeviceId(_) => ProfileError::MissingDeviceId { side },
        ReplicaLocationError::UnexpectedDeviceId(_) => ProfileError::UnexpectedDeviceId { side },
    })
}

fn globs(rules: &Table, key: &str) -> Result<Vec<Glob>, ProfileError> {
    strings(rules, "rules.", key)?
        .into_iter()
        .map(|pattern| Glob::new(pattern).map_err(|e| invalid(&format!("rules.{key}"), e)))
        .collect()
}

/// `[ssh.<side>]`, or the default access when absent. An empty option or
/// command is refused here, where its key can be named, rather than failing
/// inside ssh far from the profile that caused it.
fn ssh_access(ssh: &Table, side: Side) -> Result<SshAccess, ProfileError> {
    let prefix = format!("ssh.{side}.");
    let table = table(ssh, side.key(), "ssh.")?;
    check_keys(table, SSH_KEYS, &prefix)?;
    let options = strings(table, &prefix, "options")?
        .into_iter()
        .map(|word| {
            SshOption::new(word)
                .map_err(|_| invalid(&format!("{prefix}options"), "an option is the empty string"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let command = match string(table, &prefix, "command")? {
        Some(text) => SshCommand::new(text).map_err(|e| invalid(&format!("{prefix}command"), e))?,
        None => SshCommand::default(),
    };
    Ok(SshAccess::new(options, command))
}

/// A profile's name: its file name under the profile store without
/// `.toml`. Uniqueness is the store's rule (it sees every name); this is
/// the rule on the one value - a name that is a safe file name on every
/// platform the store runs on:
///
/// - 1 to 64 characters: letters and digits (any script), space, `-`,
///   `_` and `.`;
/// - not starting with `-` (it would read as a flag in `dsync sync <name>`)
///   or `.` (hidden, and `.`/`..` are not names), and not ending with a
///   space or `.` (Windows strips those, so two names would be one file);
/// - not a Windows device name (`CON`, `NUL`, `COM1`, ...) in any case,
///   with or without an extension.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
pub struct ProfileName(String);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProfileNameError {
    #[error("a profile name must be 1 to {max} characters", max = ProfileName::MAX_CHARS)]
    Length,
    #[error("profile name {0:?} may only hold letters, digits, spaces, \"-\", \"_\" and \".\"")]
    Character(String),
    #[error("profile name {0:?} cannot start with \"-\" or \".\" or end with a space or \".\"")]
    Edge(String),
    #[error("profile name {0:?} is reserved on Windows")]
    Reserved(String),
}

impl ProfileName {
    pub const MAX_CHARS: usize = 64;

    pub fn parse(text: &str) -> Result<ProfileName, ProfileNameError> {
        let count = text.chars().count();
        if count == 0 || count > Self::MAX_CHARS {
            return Err(ProfileNameError::Length);
        }
        let allowed = |c: char| c.is_alphanumeric() || matches!(c, ' ' | '-' | '_' | '.');
        if !text.chars().all(allowed) {
            return Err(ProfileNameError::Character(text.to_owned()));
        }
        if text.starts_with(['-', '.']) || text.ends_with([' ', '.']) {
            return Err(ProfileNameError::Edge(text.to_owned()));
        }
        let stem = text.split('.').next().unwrap_or(text).trim_end();
        if is_windows_device(stem) {
            return Err(ProfileNameError::Reserved(text.to_owned()));
        }
        Ok(ProfileName(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn is_windows_device(stem: &str) -> bool {
    let upper = stem.to_ascii_uppercase();
    match upper.as_str() {
        "CON" | "PRN" | "AUX" | "NUL" => true,
        _ => {
            let base = upper.get(..3);
            let digit = upper.get(3..).map(str::as_bytes);
            matches!(base, Some("COM" | "LPT")) && matches!(digit, Some([b'1'..=b'9']))
        }
    }
}

impl FromStr for ProfileName {
    type Err = ProfileNameError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        ProfileName::parse(text)
    }
}

impl fmt::Display for ProfileName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
