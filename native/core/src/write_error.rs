//! Why one file's write failed: which file, at which stage, and the OS's
//! own error. A per-path failure (SPEC §7.6's blast radius), not the end of
//! the transfer.

use std::fmt;
use std::io;

use dsync_domain::RelPath;

use crate::write_stats::Stage;

#[derive(Debug)]
pub struct WriteError {
    pub path: RelPath,
    pub stage: Stage,
    pub source: io::Error,
}

impl WriteError {
    pub fn kind(&self) -> io::ErrorKind {
        self.source.kind()
    }

    /// The errno, where the error came from the OS.
    pub fn os_code(&self) -> Option<i32> {
        self.source.raw_os_error()
    }
}

impl fmt::Display for WriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "writing {} failed at {}: {:?}",
            self.path,
            self.stage,
            self.kind()
        )?;
        match self.os_code() {
            Some(code) => write!(f, " (os error {code})"),
            None => write!(f, " ({})", self.source),
        }
    }
}

impl std::error::Error for WriteError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}
