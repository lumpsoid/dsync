//! What a user can attach to a bug report: panics, the head's own errors
//! and each run's key events, one timestamped line each, in
//! `<state>/diagnostics.log` ([`crate::StateDir::diagnostics_log`]).
//!
//! Small by design - it rotates to `diagnostics.log.1` past
//! [`ROTATE_AT_BYTES`] - and free of the user's data: no file contents,
//! and no file paths but what an error message itself names. What each
//! run touched is [`crate::RunHistory`]'s, which is never part of it.

use std::io;

use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::rotating_file::RotatingFile;
use crate::state_dir::StateDir;

/// The size past which the log starts a new file.
const ROTATE_AT_BYTES: u64 = 256 * 1024;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct DiagnosticsLog {
    file: RotatingFile,
}

impl DiagnosticsLog {
    pub fn new(state: &StateDir) -> DiagnosticsLog {
        DiagnosticsLog {
            file: RotatingFile {
                path: state.diagnostics_log(),
                rotate_at: ROTATE_AT_BYTES,
            },
        }
    }

    /// Appends `message` as one entry stamped with the time now (UTC). A
    /// message of several lines keeps them, each after the first indented,
    /// so every entry starts with its stamp.
    pub fn note(&self, message: &str) -> io::Result<()> {
        let at = OffsetDateTime::now_utc()
            .replace_nanosecond(0)
            .map_err(io::Error::other)?
            .format(&Rfc3339)
            .map_err(io::Error::other)?;
        let body = message.trim_end().replace('\n', "\n  ");
        self.file.append(format!("{at} {body}\n").as_bytes())
    }

    /// Everything kept, oldest first.
    pub fn read(&self) -> io::Result<String> {
        Ok(self
            .file
            .read()?
            .iter()
            .map(|bytes| String::from_utf8_lossy(bytes))
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_back_stamped_entries_oldest_first() {
        let dir = tempfile::tempdir().unwrap();
        let log = DiagnosticsLog::new(&StateDir::new(dir.path().join("state")));
        assert_eq!(log.read().unwrap(), "");
        log.note("first").unwrap();
        log.note("second\nwith a second line\n").unwrap();
        let text = log.read().unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3, "{text}");
        assert!(lines[0].ends_with("Z first"), "{text}");
        assert!(lines[1].ends_with("Z second"), "{text}");
        assert_eq!(lines[2], "  with a second line");
    }

    #[test]
    fn rotates_past_its_size_keeping_one_previous_file() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = DiagnosticsLog::new(&StateDir::new(dir.path()));
        // A stamp, a space, a one-digit message and a newline.
        let entry = "2026-11-03T14:06:10Z 1\n".len() as u64;
        log.file.rotate_at = 2 * entry;
        for n in 1..=5 {
            log.note(&n.to_string()).unwrap();
        }
        let kept: Vec<String> = log
            .read()
            .unwrap()
            .lines()
            .map(|line| line.rsplit(' ').next().unwrap().to_owned())
            .collect();
        assert_eq!(kept, ["3", "4", "5"]);
    }
}
