//! A profile (SPEC §12), parsed from its TOML text.

use std::fmt;
use std::str::FromStr;
use std::sync::LazyLock;

use toml::{Table, Value};

use crate::device_id::DeviceId;
use crate::effective_options::EffectiveOptions;
use crate::entry::{Entry, EntryError};
use crate::entry_id::CanonicalSide;
use crate::format_version::FormatVersion;
use crate::glob::Glob;
use crate::host_facts::HostFacts;
use crate::jobs::Jobs;
use crate::location::Location;
use crate::options_error::OptionsError;
use crate::platform::Platform;
use crate::replica_location::{ReplicaLocation, ReplicaLocationError};
use crate::root_kind::RootKind;
use crate::rule_set::RuleSet;
use crate::run_flags::RunFlags;
use crate::side::Side;
use crate::ssh_access::{SshAccess, SshCommand, SshOption};

#[cfg(test)]
mod tests;

/// A profile: the entries (root pairs) a run syncs, its rules and
/// options, and how ssh reaches each side.
///
/// The schema is SPEC §12's: `[[entries]]`, each with `a`, `b` and an
/// optional `kind` (`folder`, the default, or `file`). Every entry's side
/// A is on one endpoint, and every entry's side B on one - a profile is "a
/// place on this side and a place on the other", and `[ssh.a]`/`[ssh.b]`
/// are per side. A `peer://` side's device id is `[devices] a`/`b`, so a
/// renamed peer does not break the profile; it is required for a
/// `peer://` side and refused for any other. Every table and key is
/// optional except at least one entry with its `a` and `b`; an unknown
/// one is an error - a misspelled key silently ignored is how a profile
/// quietly stops ignoring `**/.git` - unless the profile's `version` is a
/// later minor than [`PROFILE_FORMAT_VERSION`], whose additions this
/// build cannot know.
///
/// Whether entries overlap needs the host's facts (`~`, the working
/// directory), so it is [`Profile::options`]' refusal, not a parse error.
///
/// `warn_size_bytes` and `jobs` stay `None` when unset, so a flag can be
/// told apart from a profile default when options are merged.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Profile {
    entries: Vec<Entry>,
    rules: RuleSet,
    warn_size_bytes: Option<u64>,
    jobs: Option<Jobs>,
    ssh_a: SshAccess,
    ssh_b: SshAccess,
}

/// The profile's format (SPEC §8.4, §12), written as the top-level
/// `version`. A new key is a minor bump; any change to what an existing
/// one means is a major one.
pub const PROFILE_FORMAT_VERSION: FormatVersion = FormatVersion::new(1, 0);

/// What a profile without a `version` is: the first format, whatever build
/// reads it, so a hand-written profile need not name one.
const UNVERSIONED: FormatVersion = FormatVersion::new(1, 0);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProfileError {
    #[error("not valid TOML: {0}")]
    Toml(String),
    #[error("unknown key: {0}")]
    UnknownKey(String),
    #[error(
        "format {found}, which this build (format {PROFILE_FORMAT_VERSION}) cannot read; use a \
         dsync that reads format {}.x, or write the profile again for this one",
        found.major()
    )]
    ForeignVersion { found: FormatVersion },
    #[error("a profile needs at least one [[entries]] with an a and a b")]
    NoEntries,
    #[error("entries[{entry}].{side} is missing")]
    MissingLocation { entry: usize, side: Side },
    #[error("entries[{entry}].{side} is a peer:// location; set devices.{side} to its device id")]
    MissingDeviceId { entry: usize, side: Side },
    #[error("devices.{side} is set, but entries[{entry}].{side} is not a peer:// location")]
    UnexpectedDeviceId { entry: usize, side: Side },
    #[error(
        "entries[{entry}].{side} is not on the endpoint of entries[0].{side}; every entry's side \
         {side} must be on the same host, socket or peer"
    )]
    MixedEndpoints { side: Side, entry: usize },
    #[error("invalid {key}: {reason}")]
    InvalidValue { key: String, reason: String },
}

const TOP_KEYS: &[&str] = &["version", "devices", "entries", "rules", "options", "ssh"];
const DEVICE_KEYS: &[&str] = &["a", "b"];
const ENTRY_KEYS: &[&str] = &["kind", "a", "b"];
const RULE_KEYS: &[&str] = &["ignore", "follow"];
const OPTION_KEYS: &[&str] = &["warn_size_bytes", "jobs"];
const SSH_SIDES: &[&str] = &["a", "b"];
const SSH_KEYS: &[&str] = &["options", "command"];

impl Profile {
    /// A profile of `entries` built from values, as the head creates one
    /// (plan OQ1): no rules, no options, default ssh access until the
    /// `with_` calls below add them. Refused without an entry, or when
    /// entries put one side on two endpoints.
    pub fn new(entries: Vec<Entry>) -> Result<Profile, ProfileError> {
        let Some(first) = entries.first() else {
            return Err(ProfileError::NoEntries);
        };
        for (index, entry) in entries.iter().enumerate().skip(1) {
            for side in Side::BOTH {
                if !entry.replica(side).same_endpoint(first.replica(side)) {
                    return Err(ProfileError::MixedEndpoints { side, entry: index });
                }
            }
        }
        Ok(Profile {
            entries,
            rules: RuleSet::default(),
            warn_size_bytes: None,
            jobs: None,
            ssh_a: SshAccess::default(),
            ssh_b: SshAccess::default(),
        })
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
        let version = match string(&root, "", "version")? {
            Some(text) => FormatVersion::parse(text).map_err(|e| invalid("version", e))?,
            None => UNVERSIONED,
        };
        PROFILE_FORMAT_VERSION
            .agree(version)
            .map_err(|mismatch| ProfileError::ForeignVersion {
                found: mismatch.theirs(),
            })?;
        let keys = KnownKeys {
            strict: !PROFILE_FORMAT_VERSION.is_older_minor_of(version),
        };
        keys.check(&root, TOP_KEYS, "")?;

        let devices = table(&root, "devices", "")?;
        keys.check(devices, DEVICE_KEYS, "devices.")?;
        let devices = [device(devices, Side::A)?, device(devices, Side::B)?];
        let entries = entry_tables(&root)?
            .into_iter()
            .enumerate()
            .map(|(index, table)| entry(index, table, &devices, platform, keys))
            .collect::<Result<Vec<_>, _>>()?;
        let bare = Profile::new(entries)?;

        let rules = table(&root, "rules", "")?;
        keys.check(rules, RULE_KEYS, "rules.")?;
        let rules = RuleSet::new(globs(rules, "ignore")?, globs(rules, "follow")?);

        let options = table(&root, "options", "")?;
        keys.check(options, OPTION_KEYS, "options.")?;
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
        keys.check(ssh, SSH_SIDES, "ssh.")?;

        Ok(Profile {
            rules,
            warn_size_bytes,
            jobs,
            ssh_a: ssh_access(ssh, Side::A, keys)?,
            ssh_b: ssh_access(ssh, Side::B, keys)?,
            ..bare
        })
    }

    /// The entries, in the order written; never empty.
    pub fn entries(&self) -> &[Entry] {
        &self.entries
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
        let mut root = Table::new();
        root.insert(
            "version".to_owned(),
            PROFILE_FORMAT_VERSION.to_string().into(),
        );
        // Every entry's side is on one endpoint, so the first names the
        // device of each.
        let mut devices = Table::new();
        for side in Side::BOTH {
            if let Some(device) = self.entries[0].replica(side).peer_device() {
                devices.insert(side.key().to_owned(), device.to_string().into());
            }
        }
        insert_unless_empty(&mut root, "devices", devices);
        let entries = self.entries.iter().map(|entry| {
            let mut table = Table::new();
            if entry.kind() == RootKind::File {
                table.insert("kind".to_owned(), entry.kind().key().into());
            }
            for side in Side::BOTH {
                table.insert(
                    side.key().to_owned(),
                    entry.replica(side).to_string().into(),
                );
            }
            Value::Table(table)
        });
        root.insert("entries".to_owned(), Value::Array(entries.collect()));

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

    /// The options of each entry, in entry order, under this run's flags;
    /// `name` is for messages.
    ///
    /// Refused when any two of the entries' 2N sides overlap once
    /// canonicalized ([`CanonicalSide::overlaps`]): an entry's own A and B,
    /// or any side of one entry and any side of another on the same
    /// endpoint - entry 1's A inside entry 2's B when both sides are this
    /// host, too. Nested roots would sync one file twice, through two
    /// archives that each believe they own it. Also refused, for now, is
    /// any single-file entry (the replica cannot open one yet).
    pub fn options(
        &self,
        name: &ProfileName,
        flags: &RunFlags,
        facts: &HostFacts,
    ) -> Result<Vec<EffectiveOptions>, OptionsError> {
        let canonical = self
            .entries
            .iter()
            .map(|entry| {
                Ok((
                    CanonicalSide::of(entry.replica(Side::A), facts)?,
                    CanonicalSide::of(entry.replica(Side::B), facts)?,
                ))
            })
            .collect::<Result<Vec<_>, OptionsError>>()?;
        let sides: Vec<(String, &CanonicalSide)> = canonical
            .iter()
            .enumerate()
            .flat_map(|(index, (a, b))| {
                [
                    (format!("entries[{index}].a"), a),
                    (format!("entries[{index}].b"), b),
                ]
            })
            .collect();
        for (at, (first, first_side)) in sides.iter().enumerate() {
            if let Some((second, second_side)) = sides[at + 1..]
                .iter()
                .find(|(_, other)| first_side.overlaps(other))
            {
                return Err(OptionsError::EntriesOverlap {
                    profile: name.to_string(),
                    first: first.clone(),
                    first_path: first_side.to_string(),
                    second: second.clone(),
                    second_path: second_side.to_string(),
                });
            }
        }
        if let Some(entry) = self
            .entries
            .iter()
            .position(|entry| entry.kind() == RootKind::File)
        {
            return Err(OptionsError::FileEntryUnsupported {
                profile: name.to_string(),
                entry,
            });
        }
        Ok(self
            .entries
            .iter()
            .zip(&canonical)
            .map(|(entry, (a, b))| EffectiveOptions::for_entry(self, entry, (a, b), flags))
            .collect())
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

/// Whether a key this build does not know is an error: always, except in
/// a profile of a later minor, where it is that minor's addition.
#[derive(Clone, Copy)]
struct KnownKeys {
    strict: bool,
}

impl KnownKeys {
    fn check(self, table: &Table, known: &[&str], prefix: &str) -> Result<(), ProfileError> {
        match table.keys().find(|key| !known.contains(&key.as_str())) {
            Some(key) if self.strict => Err(ProfileError::UnknownKey(format!("{prefix}{key}"))),
            _ => Ok(()),
        }
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

/// `devices.<side>`: the device id every entry's `peer://` side `side`
/// resolved to.
fn device(devices: &Table, side: Side) -> Result<Option<DeviceId>, ProfileError> {
    string(devices, "devices.", side.key())?
        .map(|text| DeviceId::from_str(text).map_err(|e| invalid(&format!("devices.{side}"), e)))
        .transpose()
}

/// The `[[entries]]` tables; absent and empty read the same: there is
/// nothing to sync.
fn entry_tables(root: &Table) -> Result<Vec<&Table>, ProfileError> {
    let items = match root.get("entries") {
        None => return Err(ProfileError::NoEntries),
        Some(Value::Array(items)) if items.is_empty() => return Err(ProfileError::NoEntries),
        Some(Value::Array(items)) => items,
        Some(_) => return Err(invalid("entries", "expected an array of tables")),
    };
    items
        .iter()
        .enumerate()
        .map(|(index, item)| match item {
            Value::Table(table) => Ok(table),
            _ => Err(invalid(&format!("entries[{index}]"), "expected a table")),
        })
        .collect()
}

/// `entries[index]`: its kind and its two sides, each pinned to its
/// side's device when `peer://`.
fn entry(
    index: usize,
    table: &Table,
    devices: &[Option<DeviceId>; 2],
    platform: Platform,
    keys: KnownKeys,
) -> Result<Entry, ProfileError> {
    let prefix = format!("entries[{index}].");
    keys.check(table, ENTRY_KEYS, &prefix)?;
    let kind = match string(table, &prefix, "kind")? {
        None => RootKind::default(),
        Some(text) => RootKind::from_key(text).ok_or_else(|| {
            invalid(
                &format!("{prefix}kind"),
                format!("expected \"file\" or \"folder\", got {text:?}"),
            )
        })?,
    };
    let [a, b] = [(Side::A, devices[0]), (Side::B, devices[1])]
        .map(|(side, device)| replica(index, table, side, device, platform));
    Entry::new(kind, a?, b?).map_err(|e| {
        let side = match e {
            EntryError::PeerHome { side } | EntryError::NoFileName { side } => side,
        };
        invalid(&format!("{prefix}{side}"), e)
    })
}

/// `entries[index].<side>`. Missing and empty read the same: there is no
/// replica to sync.
fn replica(
    index: usize,
    table: &Table,
    side: Side,
    device: Option<DeviceId>,
    platform: Platform,
) -> Result<ReplicaLocation, ProfileError> {
    let prefix = format!("entries[{index}].");
    let raw = match string(table, &prefix, side.key())? {
        Some(raw) if !raw.is_empty() => raw,
        _ => return Err(ProfileError::MissingLocation { entry: index, side }),
    };
    let location =
        Location::parse(raw, platform).map_err(|e| invalid(&format!("{prefix}{side}"), e))?;
    ReplicaLocation::new(location, device).map_err(|e| match e {
        ReplicaLocationError::MissingDeviceId(_) => {
            ProfileError::MissingDeviceId { entry: index, side }
        }
        ReplicaLocationError::UnexpectedDeviceId(_) => {
            ProfileError::UnexpectedDeviceId { entry: index, side }
        }
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
fn ssh_access(ssh: &Table, side: Side, keys: KnownKeys) -> Result<SshAccess, ProfileError> {
    let prefix = format!("ssh.{side}.");
    let table = table(ssh, side.key(), "ssh.")?;
    keys.check(table, SSH_KEYS, &prefix)?;
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
