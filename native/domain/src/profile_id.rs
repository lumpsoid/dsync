//! The one id a replica pair's archive, lock and state files are named by.

use std::fmt;
use std::str::FromStr;

use sha2::{Digest, Sha256};

use crate::device_id::DeviceId;
use crate::hex;
use crate::host_facts::HostFacts;
use crate::location::{ExpandError, expand_home};
use crate::platform::Platform;
use crate::replica_location::ReplicaLocation;

/// One replica's identity, independent of how it is reached or spelled.
///
/// - A local path has `~` and `$VAR`/`${VAR}` expanded (an unknown variable
///   is left as typed), is resolved against the working directory when
///   still relative, and loses one trailing separator. Without the working
///   directory, `notes` typed in two directories would be one replica.
/// - An ssh side is `[user@]host:path`, the same whether written unschemed
///   or as `ssh://`: how a tree is reached says nothing about which tree it
///   is. Its path is only stripped of one trailing `/`; `~` and relative
///   paths resolve on the far side, which cannot be known here.
/// - A unix side is its socket and path; a peer side is its **device id**
///   and path, never its name, so renaming a peer keeps the identity.
///
/// Built only from a [`ReplicaLocation`], so a peer side cannot be
/// canonicalized without its device id.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct CanonicalSide(Kind);

#[derive(Clone, PartialEq, Eq, Debug)]
enum Kind {
    Local {
        path: String,
    },
    Ssh {
        user: Option<String>,
        host: String,
        path: String,
    },
    Unix {
        socket: String,
        path: String,
    },
    Peer {
        device: DeviceId,
        path: String,
    },
}

impl CanonicalSide {
    pub fn of(replica: &ReplicaLocation, facts: &HostFacts) -> Result<CanonicalSide, ExpandError> {
        let kind = match replica {
            ReplicaLocation::Local(local) => Kind::Local {
                path: canonical_local_path(local.path(), facts)?,
            },
            ReplicaLocation::Ssh(ssh) => Kind::Ssh {
                user: ssh.user().map(str::to_owned),
                host: ssh.host().to_owned(),
                path: remote_path(ssh.path()),
            },
            ReplicaLocation::Unix(unix) => Kind::Unix {
                socket: unix.socket().to_owned(),
                path: remote_path(unix.path()),
            },
            ReplicaLocation::Peer(peer, device) => Kind::Peer {
                device: *device,
                path: remote_path(peer.path()),
            },
        };
        Ok(CanonicalSide(kind))
    }

    /// An unambiguous byte encoding: a tag, then length-prefixed fields, so
    /// no field's content can shift a boundary.
    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        let mut field = |bytes: &[u8]| {
            out.extend_from_slice(&(bytes.len() as u64).to_be_bytes());
            out.extend_from_slice(bytes);
        };
        match &self.0 {
            Kind::Local { path } => {
                field(b"local");
                field(path.as_bytes());
            }
            Kind::Ssh { user, host, path } => {
                field(b"ssh");
                field(user.as_deref().unwrap_or("").as_bytes());
                field(host.as_bytes());
                field(path.as_bytes());
            }
            Kind::Unix { socket, path } => {
                field(b"unix");
                field(socket.as_bytes());
                field(path.as_bytes());
            }
            Kind::Peer { device, path } => {
                field(b"peer");
                field(device.as_bytes());
                field(path.as_bytes());
            }
        }
        out
    }
}

/// The canonical form, for messages ("the two locations are the same once
/// expanded: ...").
impl fmt::Display for CanonicalSide {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.0 {
            Kind::Local { path } => f.write_str(path),
            Kind::Ssh { user, host, path } => match user {
                Some(user) => write!(f, "{user}@{host}:{path}"),
                None => write!(f, "{host}:{path}"),
            },
            Kind::Unix { socket, path } => write!(f, "unix://{socket}:{path}"),
            Kind::Peer { device, path } => write!(f, "peer://{device}:{path}"),
        }
    }
}

fn canonical_local_path(path: &str, facts: &HostFacts) -> Result<String, ExpandError> {
    let expanded = expand_vars(&expand_home(path, facts.home())?, facts);
    let platform = facts.platform();
    let resolved = if is_absolute(&expanded, platform) {
        expanded
    } else {
        let cwd = without_trailing_slash(facts.cwd(), platform);
        let separator = match platform {
            Platform::Unix => '/',
            Platform::Windows => '\\',
        };
        format!("{cwd}{separator}{expanded}")
    };
    Ok(without_trailing_slash(&resolved, platform).to_owned())
}

/// A far side's path: `~` and relative paths resolve there, so only the
/// trailing `/` is normalized.
fn remote_path(path: &str) -> String {
    without_trailing_slash(path, Platform::Unix).to_owned()
}

fn is_absolute(path: &str, platform: Platform) -> bool {
    match platform {
        Platform::Unix => path.starts_with('/'),
        Platform::Windows => {
            let bytes = path.as_bytes();
            let drive_rooted = bytes.len() >= 3
                && bytes[0].is_ascii_alphabetic()
                && bytes[1] == b':'
                && matches!(bytes[2], b'\\' | b'/');
            drive_rooted || path.starts_with('\\') || path.starts_with('/')
        }
    }
}

fn without_trailing_slash(path: &str, platform: Platform) -> &str {
    let is_separator = |c: char| c == '/' || (platform == Platform::Windows && c == '\\');
    match path.char_indices().last() {
        Some((last, c)) if last > 0 && is_separator(c) => &path[..last],
        _ => path,
    }
}

/// Replaces each `$NAME` / `${NAME}` (NAME: ASCII letters, digits, `_`)
/// with its value; a name the host does not have stays as typed.
fn expand_vars(path: &str, facts: &HostFacts) -> String {
    let is_name = |c: char| c.is_ascii_alphanumeric() || c == '_';
    let mut out = String::with_capacity(path.len());
    let mut rest = path;
    while let Some(dollar) = rest.find('$') {
        out.push_str(&rest[..dollar]);
        let after = &rest[dollar + 1..];
        let (name, consumed) = match after.strip_prefix('{') {
            Some(braced) => match braced.find('}') {
                Some(end) if end > 0 && braced[..end].chars().all(is_name) => {
                    (&braced[..end], end + 2)
                }
                _ => ("", 0),
            },
            None => {
                let end = after.find(|c: char| !is_name(c)).unwrap_or(after.len());
                (&after[..end], end)
            }
        };
        let reference = &rest[dollar..dollar + 1 + consumed];
        match facts.var(name).filter(|_| !name.is_empty()) {
            Some(value) => out.push_str(value),
            None => out.push_str(reference),
        }
        rest = &rest[dollar + 1 + consumed..];
    }
    out.push_str(rest);
    out
}

/// The id every state file of a replica pair is named by
/// (`<state>/<id>-a.jsonl`, ...): 32 lowercase hex digits, file-name-safe
/// on every platform.
///
/// **One derivation** for named profiles, head profiles and ad-hoc runs
/// (plan OQ6): SHA-256 over the two [`CanonicalSide`]s in sorted order,
/// truncated to 128 bits. So the same pair in either order has one id; a
/// renamed profile or peer keeps its archive; a peer re-paired under a new
/// key gets a new id and a first sync; and a named profile and an ad-hoc
/// run over the same pair share an archive - the archive records what two
/// replicas last agreed on, and rules only filter it.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
pub struct ProfileId(String);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0:?} is not a profile id (32 lowercase hex digits)")]
pub struct ProfileIdError(String);

impl ProfileId {
    const DOMAIN: &[u8] = b"dsync-profile:v1";

    pub fn for_pair(a: &CanonicalSide, b: &CanonicalSide) -> ProfileId {
        let (first, second) = {
            let (a, b) = (a.encode(), b.encode());
            if a <= b { (a, b) } else { (b, a) }
        };
        let mut hasher = Sha256::new();
        hasher.update(Self::DOMAIN);
        hasher.update(&first);
        hasher.update(&second);
        let digest = hasher.finalize();
        ProfileId(hex::encode(&digest[..16]))
    }

    /// Reads an id back, e.g. from a state file name.
    pub fn parse(text: &str) -> Result<ProfileId, ProfileIdError> {
        let well_formed = text.len() == 32
            && text
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        if !well_formed {
            return Err(ProfileIdError(text.to_owned()));
        }
        Ok(ProfileId(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for ProfileId {
    type Err = ProfileIdError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        ProfileId::parse(text)
    }
}

impl fmt::Display for ProfileId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests;
