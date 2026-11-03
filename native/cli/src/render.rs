//! What a run shows (SPEC §11.4): human text, or JSON Lines on stdout.
//!
//! Human mode writes the run to stdout and failures to stderr; `--json`
//! writes one object per event to stdout and nothing else there, so the
//! stream stays parseable. Either way the interrupt note and `--timings`
//! go to stderr (the caller prints those).

mod human;
mod json;
pub mod words;

use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use dsync_core::{
    ConnectError, EntryReport, ListedEntry, PeerContact, ReconnectCause, RunEvent, SshLaunch,
    StateDir,
};
use dsync_domain::{
    EffectiveOptions, EntryId, Locality, Location, ProfileName, ReplicaLocation, RuleSet, Side,
};
use time::UtcOffset;

pub use human::HumanRenderer;
pub use json::JsonRenderer;

/// `at` as an RFC 3339 UTC timestamp, for listings; `None` only past what
/// the format can write (the year 9999).
pub fn rfc3339(at: SystemTime) -> Option<String> {
    time::OffsetDateTime::from(at)
        .format(&time::format_description::well_known::Rfc3339)
        .ok()
}

/// How a replica is reached, as the run header names it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Transport {
    Local,
    Ssh,
    Socket,
    Peer,
}

impl Transport {
    /// A location this process serves itself is local, whatever its
    /// spelling; otherwise its scheme says.
    pub fn of(location: &Location, locality: Locality) -> Transport {
        match (locality, location) {
            (Locality::InProcess, _) | (_, Location::Local(_)) => Transport::Local,
            (Locality::Remote, Location::Ssh(_)) => Transport::Ssh,
            (Locality::Remote, Location::Unix(_)) => Transport::Socket,
            (Locality::Remote, Location::Peer(_)) => Transport::Peer,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Transport::Local => "local",
            Transport::Ssh => "ssh",
            Transport::Socket => "socket",
            Transport::Peer => "peer",
        }
    }
}

/// One replica as the run header shows it.
#[derive(Clone, Debug)]
pub struct ReplicaView {
    pub location: ReplicaLocation,
    pub locality: Locality,
    /// The lock file, for a replica this process opens itself.
    pub lock: Option<PathBuf>,
    /// ssh's arguments, for a replica reached over ssh.
    pub ssh_args: Option<Vec<String>>,
}

impl ReplicaView {
    pub fn transport(&self) -> Transport {
        Transport::of(&self.location.to_location(), self.locality)
    }

    /// The device a folder of this replica is on, for a message about it;
    /// `None` for this machine.
    pub fn device(&self) -> Option<String> {
        match (self.transport(), self.location.to_location()) {
            (Transport::Local, _) => None,
            (_, Location::Ssh(ssh)) => Some(ssh.destination()),
            (_, Location::Unix(unix)) => Some(format!("the agent at {}", unix.socket())),
            (_, Location::Peer(peer)) => Some(peer.device().to_string()),
            (_, Location::Local(_)) => None,
        }
    }
}

/// Which run this is: a named profile's, or two typed locations'.
#[derive(Clone, Debug)]
pub enum RunName {
    Profile(ProfileName),
    AdHoc,
}

/// What the renderers know about a run besides its events.
#[derive(Clone, Debug)]
pub struct RunView {
    pub name: RunName,
    pub entry_id: EntryId,
    pub rules: RuleSet,
    pub warn_size_bytes: Option<u64>,
    pub a: ReplicaView,
    pub b: ReplicaView,
}

impl RunView {
    /// The view of `options`, run as `name`, on a host with
    /// `local_addresses`, keeping its locks in `state`.
    pub fn of(
        name: RunName,
        options: &EffectiveOptions,
        local_addresses: &[String],
        state: &StateDir,
    ) -> RunView {
        let replica = |side| {
            let location = options.replica(side).clone();
            let typed = location.to_location();
            let locality = typed.locality(local_addresses);
            let transport = Transport::of(&typed, locality);
            ReplicaView {
                lock: (transport == Transport::Local).then(|| state.lock(&options.entry_id, side)),
                ssh_args: match (&typed, transport) {
                    (Location::Ssh(ssh), Transport::Ssh) => Some(
                        SshLaunch::new(options.ssh(side), ssh.user(), ssh.host())
                            .args()
                            .to_vec(),
                    ),
                    _ => None,
                },
                location,
                locality,
            }
        };
        RunView {
            name,
            entry_id: options.entry_id.clone(),
            rules: options.rules.clone(),
            warn_size_bytes: options.warn_size_bytes,
            a: replica(Side::A),
            b: replica(Side::B),
        }
    }

    pub fn replica(&self, side: Side) -> &ReplicaView {
        match side {
            Side::A => &self.a,
            Side::B => &self.b,
        }
    }
}

/// The wall clock the header's "last synced" reads against.
#[derive(Clone, Copy, Debug)]
pub struct Wallclock {
    pub now: SystemTime,
    pub offset: UtcOffset,
}

/// The run's renderer, as the flags chose it.
pub enum Renderer<O: Write, E: Write> {
    Human(HumanRenderer<O, E>),
    Json(JsonRenderer<O>),
}

impl<O: Write, E: Write> Renderer<O, E> {
    pub fn render(&mut self, event: &RunEvent) {
        match self {
            Renderer::Human(human) => human.render(event),
            Renderer::Json(json) => json.render(event),
        }
    }

    /// The header's peer notes; human mode only, as the Dart CLI's were.
    pub fn peer_contacts(&mut self, peers: &[PeerContact]) {
        if let Renderer::Human(human) = self {
            human.peer_contacts(peers);
        }
    }

    /// A profile's entries, before the first is connected: `--json`'s
    /// leading `entries` line. Human mode says it per entry instead, as
    /// each one starts ([`Renderer::enter_entry`]).
    pub fn entries_listed(&mut self, list: &[ListedEntry]) {
        if let Renderer::Json(json) = self {
            json.entries_listed(list);
        }
    }

    /// Moves to `index`'s events, of `total`: human mode's `[i/total]`
    /// heading, when there is more than one; either way, the view every
    /// event after this one is read against.
    pub fn enter_entry(&mut self, index: usize, total: usize, view: RunView) {
        match self {
            Renderer::Human(human) => human.enter_entry(index, total, view),
            Renderer::Json(json) => json.enter_entry(index, view),
        }
    }

    /// An entry's side could not be connected; its run never started.
    pub fn connect_failed(&mut self, error: &ConnectError) {
        match self {
            Renderer::Human(human) => human.connect_failed(error),
            Renderer::Json(json) => json.connect_failed(error),
        }
    }

    /// The entry's dropped link is dialled again, `attempt` of them so
    /// far, `after` from now.
    pub fn reconnecting(&mut self, attempt: u32, after: Duration, cause: &ReconnectCause) {
        match self {
            Renderer::Human(human) => human.reconnecting(attempt, cause),
            Renderer::Json(json) => json.reconnecting(attempt, after, cause),
        }
    }

    /// Human mode's closing list, one line per entry, when a profile ran
    /// more than one.
    pub fn entry_outcomes(&mut self, views: &[RunView], entries: &[EntryReport]) {
        if let Renderer::Human(human) = self {
            human.entry_outcomes(views, entries);
        }
    }
}

#[cfg(test)]
pub(crate) mod fixtures {
    //! Plain values for the renderer and decider tests.

    use std::path::PathBuf;
    use std::time::{Duration, SystemTime};

    use dsync_domain::{
        Action, Conflict, ContentHash, EntryId, FileMeta, FileState, Glob, Locality, Location,
        MassDelete, MassDeletePolicy, Platform, ProfileName, Proposal, RelPath, ReplicaLocation,
        RuleSet, Side, Status, Unchanged,
    };
    use time::UtcOffset;

    use super::{ReplicaView, RunName, RunView, Wallclock};

    pub const PROFILE_ID: &str = "0123456789abcdef0123456789abcdef";

    /// `actions` as a plan proposes them, none offering a reversal.
    pub fn proposed(actions: Vec<Action>) -> Vec<Proposal> {
        actions
            .into_iter()
            .map(|action| Proposal {
                action,
                reverse_bytes: None,
            })
            .collect()
    }

    pub fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap()
    }

    /// SPEC §10's verdict on `deletes` deletions `f00`, `f01`, ... on `on`,
    /// whose archive holds `archived` files.
    pub fn mass_delete(on: Side, deletes: usize, archived: usize) -> MassDelete {
        let kept: Vec<Action> = (0..deletes)
            .map(|index| Action::Delete {
                path: path(&format!("f{index:02}")),
                on,
            })
            .collect();
        let mut sides = [0, 0];
        sides[usize::from(on == Side::B)] = archived;
        MassDeletePolicy::DEFAULT.judge(&kept, sides).unwrap()
    }

    pub fn file(size: u64) -> FileState {
        FileState {
            meta: FileMeta {
                size,
                mtime_us: 1,
                mode: 0o644,
                read_us: 0,
            },
            hash: ContentHash::from_digest([7; 32]),
        }
    }

    pub fn created(size: u64) -> Status {
        Status::Created(file(size))
    }

    pub fn unchanged(by: Unchanged) -> Status {
        Status::Unchanged { file: file(1), by }
    }

    pub fn conflict(at: &str, a: Option<Status>, b: Option<Status>) -> Conflict {
        Conflict {
            path: path(at),
            a,
            b,
            root_kind: dsync_domain::RootKind::Folder,
            cause: dsync_domain::ConflictCause::Changes,
        }
    }

    pub fn replica(location: &str, locality: Locality) -> ReplicaView {
        ReplicaView {
            location: ReplicaLocation::new(
                Location::parse(location, Platform::Unix).unwrap(),
                None,
            )
            .unwrap(),
            locality,
            lock: None,
            ssh_args: None,
        }
    }

    /// A profile run named `work` over a local A and an ssh B.
    pub fn view() -> RunView {
        RunView {
            name: RunName::Profile(ProfileName::parse("work").unwrap()),
            entry_id: EntryId::parse(PROFILE_ID).unwrap(),
            rules: RuleSet::new(vec![Glob::new("*.tmp").unwrap()], vec![]),
            warn_size_bytes: None,
            a: ReplicaView {
                lock: Some(PathBuf::from("/state/a.lock")),
                ..replica("/home/me/notes", Locality::InProcess)
            },
            b: ReplicaView {
                ssh_args: Some(vec![
                    "-T".into(),
                    "box".into(),
                    "dsync".into(),
                    "agent".into(),
                    "--stdio".into(),
                ]),
                ..replica("box:notes", Locality::Remote)
            },
        }
    }

    pub fn clock() -> Wallclock {
        Wallclock {
            now: SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000),
            offset: UtcOffset::UTC,
        }
    }
}
