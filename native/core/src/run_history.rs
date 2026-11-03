//! What each run this host started did, kept after its output is gone:
//! one [`RunRecord`] per run, as JSON Lines, in `<state>/runs.jsonl`
//! ([`crate::StateDir::run_history`]).
//!
//! Appended to, never rewritten. Once the file would grow past
//! [`ROTATE_AT_BYTES`] it is renamed to `runs.jsonl.1` - replacing the one
//! there - and a new one started, so the history costs at most twice that
//! and always holds the latest runs. A line cut short by a kill mid-append
//! is skipped on reading; every line before and after it still reads.

use std::io;

use dsync_domain::RunRecord;

use crate::rotating_file::RotatingFile;
use crate::state_dir::StateDir;

/// The size past which the history starts a new file.
const ROTATE_AT_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct RunHistory {
    file: RotatingFile,
}

impl RunHistory {
    pub fn new(state: &StateDir) -> RunHistory {
        RunHistory {
            file: RotatingFile {
                path: state.run_history(),
                rotate_at: ROTATE_AT_BYTES,
            },
        }
    }

    /// Appends `record` as one line, creating the state directory and the
    /// file if need be, rotating first when the line would take the file
    /// past its size.
    pub fn append(&self, record: &RunRecord) -> io::Result<()> {
        let mut line = serde_json::to_vec(record).map_err(io::Error::other)?;
        line.push(b'\n');
        self.file.append(&line)
    }

    /// Every run kept, oldest first.
    pub fn read(&self) -> io::Result<Vec<RunRecord>> {
        Ok(self
            .file
            .read()?
            .iter()
            .flat_map(|bytes| records(bytes))
            .collect())
    }
}

/// The records in `bytes`, a torn line skipped.
fn records(bytes: &[u8]) -> Vec<RunRecord> {
    bytes
        .split(|&byte| byte == b'\n')
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use std::fs::OpenOptions;
    use std::io::Write;

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
        let mut history = RunHistory::new(&StateDir::new(dir.path()));
        history.file.rotate_at = 2 * line;
        for started_ms in 1..=5 {
            history.append(&record(started_ms)).unwrap();
        }
        // [1, 2] rotated out by 3, [3, 4] by 5, replacing [1, 2].
        assert_eq!(started(&history), vec![3, 4, 5]);
        assert!(history.file.previous().exists());
    }
}
