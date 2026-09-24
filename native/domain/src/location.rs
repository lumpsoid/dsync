//! Where a replica is: SPEC §2's location grammar and §4.1's locality rule.

use std::fmt;
use std::str::FromStr;

use crate::peer_name::{PeerName, PeerNameError};
use crate::platform::Platform;

#[cfg(test)]
mod tests;

/// A parsed replica location (SPEC §2): a local path, `user@host:path`,
/// `ssh://[user@]destination:path`, `unix://<socket-path>:<replica-path>`
/// or `peer://<device-name>:<replica-path>`.
///
/// Parsing is purely syntactic. Whether an unschemed `user@host:path`
/// really names this machine is [`Location::locality`]'s verdict over an
/// address list the caller fetched - parsing never looks anything up.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Location {
    /// A bare path on this machine, relative or absolute, as typed.
    Local(LocalLocation),
    /// Reached over `ssh`: either the unschemed `[user@]host:path` form or
    /// an explicit `ssh://` one, which [`SshLocation::form`] tells apart.
    Ssh(SshLocation),
    /// A `dsync agent --listen` already bound to a unix socket (SPEC §4.2).
    Unix(UnixLocation),
    /// A paired device over dsync's own TLS transport (SPEC §4.4).
    Peer(PeerLocation),
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct LocalLocation {
    path: String,
}

/// How an ssh location was written, which decides its locality (SPEC §4.1).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SshForm {
    /// `[user@]host:path`: in-process when the host is this machine.
    Inferred,
    /// `ssh://...`: remote by declaration, no address consulted.
    Declared,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SshLocation {
    form: SshForm,
    user: Option<String>,
    host: String,
    path: String,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct UnixLocation {
    socket: String,
    path: String,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct PeerLocation {
    device: PeerName,
    path: String,
}

/// Where a location's agent runs (SPEC §4.1).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Locality {
    InProcess,
    Remote,
}

const SSH: &str = "ssh://";
const UNIX: &str = "unix://";
const PEER: &str = "peer://";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LocationError {
    #[error("empty location")]
    Empty,
    #[error("location {0:?} contains a NUL byte")]
    Nul(String),
    #[error("invalid location {raw:?}: the {part} is empty")]
    EmptyPart { raw: String, part: &'static str },
    #[error(
        "{raw:?}: \"{scheme}\" needs a \":\" between the {what} and the path, as in \"{example}\""
    )]
    MissingSeparator {
        raw: String,
        scheme: &'static str,
        what: &'static str,
        example: &'static str,
    },
    #[error("{0:?}: unix:// locations are not supported on this platform")]
    UnixUnsupported(String),
    #[error("{raw:?}: {source}")]
    DeviceName { raw: String, source: PeerNameError },
    #[error("{0:?} is not a path on this machine")]
    NotLocal(String),
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("cannot expand {path:?}: the home directory is not known")]
pub struct ExpandError {
    path: String,
}

impl Location {
    /// Parses `raw` by SPEC §2's grammar under `platform`'s rules.
    ///
    /// Unschemed, a colon separates a host from a path only when it comes
    /// before the first `/` (ssh's and rsync's rule), so `./log:old` and
    /// `notes` are local. On Windows a single ASCII letter before that
    /// colon is a drive (`C:\notes`, `C:/notes`), not a one-letter host -
    /// the same exception OpenSSH's own scp makes there.
    ///
    /// After a scheme, everything up to the first `:` is the destination,
    /// socket path or device name, verbatim. Only `ssh://` splits a
    /// `user@` off it. `unix://` is refused on Windows, which has no unix
    /// sockets to reach an agent through (plan D5).
    pub fn parse(raw: &str, platform: Platform) -> Result<Location, LocationError> {
        if raw.is_empty() {
            return Err(LocationError::Empty);
        }
        if raw.contains('\0') {
            return Err(LocationError::Nul(raw.to_owned()));
        }
        if let Some(rest) = raw.strip_prefix(SSH) {
            return parse_ssh_declared(raw, rest);
        }
        if let Some(rest) = raw.strip_prefix(UNIX) {
            if platform == Platform::Windows {
                return Err(LocationError::UnixUnsupported(raw.to_owned()));
            }
            let (socket, path) = split_scheme(
                raw,
                rest,
                UNIX,
                "socket path",
                "unix:///run/user/1000/dsync.sock:/srv/notes",
            )?;
            return Ok(Location::Unix(UnixLocation {
                socket: socket.to_owned(),
                path: path.to_owned(),
            }));
        }
        if let Some(rest) = raw.strip_prefix(PEER) {
            let (device, path) =
                split_scheme(raw, rest, PEER, "device name", "peer://phone:/sdcard/notes")?;
            let device = PeerName::parse(device).map_err(|source| LocationError::DeviceName {
                raw: raw.to_owned(),
                source,
            })?;
            return Ok(Location::Peer(PeerLocation {
                device,
                path: path.to_owned(),
            }));
        }
        parse_unschemed(raw, platform)
    }

    /// A path on this machine - a folder a picker returned - refused when
    /// SPEC §2 would read it as anything else, so it reads back the same
    /// from a profile.
    pub fn local(path: &str, platform: Platform) -> Result<Location, LocationError> {
        match Location::parse(path, platform)? {
            local @ Location::Local(_) => Ok(local),
            _ => Err(LocationError::NotLocal(path.to_owned())),
        }
    }

    /// `peer://<device>:<path>` from its parts, as a head builds one from a
    /// paired device and the path typed for it.
    pub fn peer(device: PeerName, path: &str) -> Result<Location, LocationError> {
        let raw = || format!("{PEER}{device}:{path}");
        if path.is_empty() {
            return Err(empty(&raw(), "path"));
        }
        if path.contains('\0') {
            return Err(LocationError::Nul(raw()));
        }
        Ok(Location::Peer(PeerLocation {
            device,
            path: path.to_owned(),
        }))
    }

    /// The replica path, as typed (unexpanded).
    pub fn path(&self) -> &str {
        match self {
            Location::Local(local) => &local.path,
            Location::Ssh(ssh) => &ssh.path,
            Location::Unix(unix) => &unix.path,
            Location::Peer(peer) => &peer.path,
        }
    }

    /// [`Location::path`] with a leading `~` replaced by `home`.
    ///
    /// A quoted path or one from a profile file never meets a shell, so a
    /// literal `~` would otherwise name a directory called `~`. `home` is
    /// the expanding side's own fact, passed in; `None` (unknown) fails
    /// loudly rather than producing a path spelled with nothing.
    pub fn expanded_path(&self, home: Option<&str>) -> Result<String, ExpandError> {
        expand_home(self.path(), home)
    }

    /// Where this location's agent runs, per SPEC §4.1.
    ///
    /// `local_addresses` are the names and addresses of this machine; the
    /// caller fetches them (only when [`Location::consults_local_addresses`]
    /// says the answer depends on them). An unschemed `host:path` is
    /// in-process when the host is `localhost` or one of those; a schemed
    /// location is remote by declaration.
    pub fn locality(&self, local_addresses: &[String]) -> Locality {
        match self {
            Location::Local(_) => Locality::InProcess,
            Location::Ssh(ssh) if ssh.form == SshForm::Inferred => {
                if ssh.host == "localhost" || local_addresses.contains(&ssh.host) {
                    Locality::InProcess
                } else {
                    Locality::Remote
                }
            }
            Location::Ssh(_) | Location::Unix(_) | Location::Peer(_) => Locality::Remote,
        }
    }

    /// Whether [`Location::locality`] would look at the address list at all:
    /// only for an unschemed `host:path`. Lets the caller skip the one piece
    /// of I/O the decision could cost.
    pub fn consults_local_addresses(&self) -> bool {
        matches!(self, Location::Ssh(ssh) if ssh.form == SshForm::Inferred)
    }
}

impl LocalLocation {
    pub fn path(&self) -> &str {
        &self.path
    }
}

impl SshLocation {
    pub fn form(&self) -> SshForm {
        self.form
    }

    pub fn user(&self) -> Option<&str> {
        self.user.as_deref()
    }

    /// The host (unschemed form) or ssh's destination, verbatim (`ssh://`):
    /// a config alias, `unix/run/ssh-unix-local/socket`, anything ssh takes.
    pub fn host(&self) -> &str {
        &self.host
    }

    /// `[user@]host` as ssh is to be handed it.
    pub fn destination(&self) -> String {
        match &self.user {
            Some(user) => format!("{user}@{}", self.host),
            None => self.host.clone(),
        }
    }

    pub fn path(&self) -> &str {
        &self.path
    }
}

impl UnixLocation {
    /// The socket path, used exactly as written (no `~` expansion).
    pub fn socket(&self) -> &str {
        &self.socket
    }

    pub fn path(&self) -> &str {
        &self.path
    }
}

impl PeerLocation {
    /// This host's label for the device; the core resolves it to a
    /// [`crate::DeviceId`] through the paired-device store.
    pub fn device(&self) -> &PeerName {
        &self.device
    }

    pub fn path(&self) -> &str {
        &self.path
    }
}

fn parse_unschemed(raw: &str, platform: Platform) -> Result<Location, LocationError> {
    let local = || {
        Location::Local(LocalLocation {
            path: raw.to_owned(),
        })
    };
    let Some(colon) = raw.find(':') else {
        return Ok(local());
    };
    if raw.find('/').is_some_and(|slash| slash < colon) {
        return Ok(local());
    }
    if platform == Platform::Windows && colon == 1 && raw.as_bytes()[0].is_ascii_alphabetic() {
        return Ok(local());
    }
    let (user, host) = split_user(raw, &raw[..colon])?;
    let path = &raw[colon + 1..];
    if host.is_empty() {
        return Err(empty(raw, "host"));
    }
    if path.is_empty() {
        return Err(empty(raw, "path"));
    }
    Ok(Location::Ssh(SshLocation {
        form: SshForm::Inferred,
        user,
        host: host.to_owned(),
        path: path.to_owned(),
    }))
}

fn parse_ssh_declared(raw: &str, rest: &str) -> Result<Location, LocationError> {
    let (destination, path) =
        split_scheme(raw, rest, SSH, "ssh destination", "ssh://alias:/srv/notes")?;
    let (user, host) = split_user(raw, destination)?;
    if host.is_empty() {
        return Err(empty(raw, "ssh destination"));
    }
    Ok(Location::Ssh(SshLocation {
        form: SshForm::Declared,
        user,
        host: host.to_owned(),
        path: path.to_owned(),
    }))
}

/// Splits a schemed location's rest at its first `:`, both halves non-empty.
fn split_scheme<'a>(
    raw: &str,
    rest: &'a str,
    scheme: &'static str,
    what: &'static str,
    example: &'static str,
) -> Result<(&'a str, &'a str), LocationError> {
    let Some((head, path)) = rest.split_once(':') else {
        return Err(LocationError::MissingSeparator {
            raw: raw.to_owned(),
            scheme,
            what,
            example,
        });
    };
    if head.is_empty() {
        return Err(empty(raw, what));
    }
    if path.is_empty() {
        return Err(empty(raw, "path"));
    }
    Ok((head, path))
}

/// Splits a leading `user@` off `destination`, refusing an empty user.
fn split_user<'a>(
    raw: &str,
    destination: &'a str,
) -> Result<(Option<String>, &'a str), LocationError> {
    match destination.split_once('@') {
        Some(("", _)) => Err(empty(raw, "user")),
        Some((user, host)) => Ok((Some(user.to_owned()), host)),
        None => Ok((None, destination)),
    }
}

fn empty(raw: &str, part: &'static str) -> LocationError {
    LocationError::EmptyPart {
        raw: raw.to_owned(),
        part,
    }
}

pub(crate) fn expand_home(path: &str, home: Option<&str>) -> Result<String, ExpandError> {
    let rest = match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => rest,
        _ => return Ok(path.to_owned()),
    };
    match home {
        Some(home) if !home.is_empty() => Ok(format!("{home}{rest}")),
        _ => Err(ExpandError {
            path: path.to_owned(),
        }),
    }
}

impl FromStr for Location {
    type Err = LocationError;

    /// Parses under the rules of the platform this binary runs on.
    fn from_str(raw: &str) -> Result<Self, Self::Err> {
        Location::parse(raw, Platform::HOST)
    }
}

/// Spelled back exactly as typed, nothing expanded: the run header shows
/// it before anything moves (SPEC §11.4), so a mistyped location reads as
/// the mistake it is.
impl fmt::Display for Location {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Location::Local(local) => f.write_str(&local.path),
            Location::Ssh(ssh) => {
                let scheme = match ssh.form {
                    SshForm::Inferred => "",
                    SshForm::Declared => SSH,
                };
                write!(f, "{scheme}{}:{}", ssh.destination(), ssh.path)
            }
            Location::Unix(unix) => write!(f, "{UNIX}{}:{}", unix.socket, unix.path),
            Location::Peer(peer) => write!(f, "{PEER}{}:{}", peer.device, peer.path),
        }
    }
}
