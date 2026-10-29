//! Why a replica connection failed: the link itself, not an operation the
//! far side ran. Every operation outstanding on a link that fails gets the
//! same one, so it is `Clone`.

use std::fmt;
use std::io;
use std::sync::Arc;
use std::time::Duration;

use dsync_domain::FormatVersion;

#[derive(Clone, Debug, thiserror::Error)]
pub enum LinkError {
    /// The far side closed the connection, or it was closed here.
    #[error("the connection to the replica closed")]
    Closed,
    /// The far side closed the connection before it answered the version
    /// handshake: the agent never started, or exited at once.
    #[error("the connection to the replica closed before the protocol handshake")]
    ClosedBeforeHandshake,
    #[error("the connection to the replica failed: {0}")]
    Io(#[source] Arc<io::Error>),
    /// The two sides speak different protocol majors (SPEC §8.4). Fatal
    /// for the caller (SPEC §11.5 exit 3).
    #[error(
        "protocol version mismatch: this side speaks {local}, the far side {remote}; \
         install dsync versions of the same major on both"
    )]
    VersionMismatch {
        local: FormatVersion,
        remote: FormatVersion,
    },
    /// What arrived in place of the far side's version frame was not this
    /// protocol at all - in practice a remote shell printing over it.
    #[error("{}", NotSpeaking { received, truncated: *truncated })]
    NotSpeakingProtocol { received: Vec<u8>, truncated: bool },
    /// What a peer:// far side sent in place of the preamble's magic: in
    /// practice a dsync from before session tokens, opening with its
    /// version frame.
    #[error(
        "the far side did not open with the peer:// preamble (it sent {received:02x?}); \
         it runs an older dsync - install the same version on both"
    )]
    NoPeerPreamble { received: Vec<u8> },
    /// The two ends' peer:// preambles differ in major.
    #[error(
        "peer:// preamble version mismatch: this side speaks {local}, the far side {remote}; \
         install dsync versions of the same major on both"
    )]
    PreambleVersionMismatch {
        local: FormatVersion,
        remote: FormatVersion,
    },
    /// A frame or message that broke the protocol after the handshake: a
    /// bug on one side or the other, never a user's configuration.
    #[error("protocol error: {0}")]
    Protocol(String),
    /// A network peer sent nothing, not even a heartbeat, for `limit`
    /// while this side was waiting to read.
    #[error("the replica went silent: nothing arrived for {limit:?}")]
    PeerSilent { limit: Duration },
    /// A link failure of an ssh transport, with what `ssh` itself printed
    /// on its stderr, which usually says why (host unreachable, auth,
    /// `dsync: command not found`).
    #[error("{cause}{}", SshSaid(stderr))]
    Ssh {
        cause: Box<LinkError>,
        stderr: Vec<String>,
    },
}

impl From<io::Error> for LinkError {
    fn from(error: io::Error) -> LinkError {
        LinkError::Io(Arc::new(error))
    }
}

/// The explanation for [`LinkError::NotSpeakingProtocol`], quoting the
/// bytes back: a login banner explains itself.
struct NotSpeaking<'a> {
    received: &'a [u8],
    truncated: bool,
}

impl fmt::Display for NotSpeaking<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "The far side is not speaking the dsync protocol (SPEC §4.2). In place of a \
             version frame it sent:\n"
        )?;
        for line in printable(self.received).lines() {
            writeln!(f, "  {line}")?;
        }
        if self.truncated {
            writeln!(f, "  …")?;
        }
        write!(
            f,
            "\nThe connection itself opened, so this is not an ssh failure - something on \
             the far side is writing to stdout, which is the stream the protocol runs \
             over. sshd sources ~/.bashrc and friends even for a non-interactive command, \
             so a login banner, an motd echo or a version manager greeting all land here. \
             The shell that runs `dsync agent --stdio` has to say nothing on stdout."
        )
    }
}

/// `bytes` as text a human recognises, every control character but tab
/// and newline replaced, so a far side that sent escape sequences cannot
/// drive the terminal this is printed on.
fn printable(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .chars()
        .map(|c| {
            if c.is_control() && c != '\n' && c != '\t' {
                '.'
            } else {
                c
            }
        })
        .collect::<String>()
        .trim_end()
        .to_owned()
}

struct SshSaid<'a>(&'a [String]);

impl fmt::Display for SshSaid<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            return Ok(());
        }
        write!(f, "\nssh said:")?;
        for line in self.0 {
            write!(f, "\n  {line}")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_a_banner_and_replaces_what_could_drive_a_terminal() {
        let error = LinkError::NotSpeakingProtocol {
            received: b"Welcome to Ubuntu\n\x1b[31mred\x07\tok".to_vec(),
            truncated: true,
        };
        let text = error.to_string();
        assert!(text.contains("  Welcome to Ubuntu\n"), "{text}");
        assert!(text.contains("  .[31mred.\tok\n  …"), "{text}");
        assert!(!text.contains('\x1b'));
    }

    #[test]
    fn an_ssh_failure_carries_what_ssh_printed() {
        let error = LinkError::Ssh {
            cause: Box::new(LinkError::ClosedBeforeHandshake),
            stderr: vec!["bash: dsync: command not found".into()],
        };
        assert_eq!(
            error.to_string(),
            "the connection to the replica closed before the protocol handshake\nssh said:\n  \
             bash: dsync: command not found"
        );
    }
}
