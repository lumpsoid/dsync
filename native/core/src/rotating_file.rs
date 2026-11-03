//! An append-only file that is kept to about twice a size: once a write
//! would take it past that size it is renamed to `<name>.1` - replacing
//! the one there - and a new one started. What [`crate::RunHistory`] and
//! [`crate::DiagnosticsLog`] keep their lines in.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, PartialEq, Eq, Debug)]
pub(crate) struct RotatingFile {
    pub(crate) path: PathBuf,
    pub(crate) rotate_at: u64,
}

impl RotatingFile {
    /// Appends `bytes` in one write, creating the parent directory and the
    /// file if need be, rotating first when they would take the file past
    /// its size.
    pub(crate) fn append(&self, bytes: &[u8]) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let size = match fs::metadata(&self.path) {
            Ok(metadata) => metadata.len(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
            Err(error) => return Err(error),
        };
        if size > 0 && size + bytes.len() as u64 > self.rotate_at {
            fs::rename(&self.path, self.previous())?;
        }
        // One write of the whole line: two writers appending at once land
        // their lines whole, one after the other.
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(bytes)?;
        file.sync_data()
    }

    /// The rotated file's bytes, then the current one's; empty for a file
    /// that is not there. Two, so a line cut short at the end of the first
    /// is never read as the start of the second's first line.
    pub(crate) fn read(&self) -> io::Result<[Vec<u8>; 2]> {
        Ok([read_or_empty(&self.previous())?, read_or_empty(&self.path)?])
    }

    pub(crate) fn previous(&self) -> PathBuf {
        let mut name = self.path.clone().into_os_string();
        name.push(".1");
        PathBuf::from(name)
    }
}

fn read_or_empty(path: &Path) -> io::Result<Vec<u8>> {
    match fs::read(path) {
        Ok(bytes) => Ok(bytes),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(error),
    }
}
