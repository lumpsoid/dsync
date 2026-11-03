//! What each run this host started did, kept after its output is gone:
//! one [`RunRecord`] per run, as JSON Lines, in `<state>/runs.jsonl`
//! ([`crate::StateDir::run_history`]).
//!
//! Appended to, never rewritten. Once the file would grow past
//! [`ROTATE_AT_BYTES`] it is renamed to `runs.jsonl.1` - replacing the one
//! there - and a new one started, so the history costs at most twice that
//! and always holds the latest runs. A line cut short by a kill mid-append
//! is skipped on reading; every line before and after it still reads.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use dsync_domain::RunRecord;

use crate::state_dir::StateDir;

/// The size past which the history starts a new file.
const ROTATE_AT_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct RunHistory {
    path: PathBuf,
    rotate_at: u64,
}

impl RunHistory {
    pub fn new(state: &StateDir) -> RunHistory {
        RunHistory {
            path: state.run_history(),
            rotate_at: ROTATE_AT_BYTES,
        }
    }

    /// Appends `record` as one line, creating the state directory and the
    /// file if need be, rotating first when the line would take the file
    /// past its size.
    pub fn append(&self, record: &RunRecord) -> io::Result<()> {
        let mut line = serde_json::to_vec(record).map_err(io::Error::other)?;
        line.push(b'\n');
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let size = match fs::metadata(&self.path) {
            Ok(metadata) => metadata.len(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
            Err(error) => return Err(error),
        };
        if size > 0 && size + line.len() as u64 > self.rotate_at {
            fs::rename(&self.path, self.previous())?;
        }
        // One write of the whole line: two runs appending at once land
        // their lines whole, one after the other.
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(&line)?;
        file.sync_data()
    }

    /// Every run kept, oldest first.
    pub fn read(&self) -> io::Result<Vec<RunRecord>> {
        let mut records = read_lines(&self.previous())?;
        records.extend(read_lines(&self.path)?);
        Ok(records)
    }

    fn previous(&self) -> PathBuf {
        let mut name = self.path.clone().into_os_string();
        name.push(".1");
        PathBuf::from(name)
    }
}

/// The records in the file at `path`; none when there is no file.
fn read_lines(path: &Path) -> io::Result<Vec<RunRecord>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    Ok(bytes
        .split(|&byte| byte == b'\n')
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect())
}

#[cfg(test)]
mod tests {
    use dsync_domain::Mode;

    use super::*;

    fn record(started_ms: u64) -> RunRecord {
        RunRecord {
            started_ms,
            ended_ms: started_ms + 1,
            profile: Some("docs".to_owned()),
            mode: Mode::Batch,
            stopped: false,
            entries: Vec::new(),
        }
    }

    fn started(history: &RunHistory) -> Vec<u64> {
        history
            .read()
            .unwrap()
            .iter()
            .map(|record| record.started_ms)
            .collect()
    }

    #[test]
    fn reads_back_what_it_appended_oldest_first() {
        let dir = tempfile::tempdir().unwrap();
        let history = RunHistory::new(&StateDir::new(dir.path().join("state")));
        assert_eq!(started(&history), Vec::<u64>::new());
        history.append(&record(1)).unwrap();
        history.append(&record(2)).unwrap();
        assert_eq!(history.read().unwrap(), vec![record(1), record(2)]);
    }

    #[test]
    fn a_line_cut_short_is_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let state = StateDir::new(dir.path());
        let history = RunHistory::new(&state);
        history.append(&record(1)).unwrap();
        let mut file = OpenOptions::new()
            .append(true)
            .open(state.run_history())
            .unwrap();
        file.write_all(b"{\"startedMs\":2,\"ende\n").unwrap();
        history.append(&record(3)).unwrap();
        assert_eq!(started(&history), vec![1, 3]);
    }

    #[test]
    fn rotates_past_its_size_keeping_one_previous_file() {
        let dir = tempfile::tempdir().unwrap();
        let line = serde_json::to_vec(&record(1)).unwrap().len() as u64 + 1;
        let history = RunHistory {
            rotate_at: 2 * line,
            ..RunHistory::new(&StateDir::new(dir.path()))
        };
        for started_ms in 1..=5 {
            history.append(&record(started_ms)).unwrap();
        }
        // [1, 2] rotated out by 3, [3, 4] by 5, replacing [1, 2].
        assert_eq!(started(&history), vec![3, 4, 5]);
        assert!(history.previous().exists());
    }
}
