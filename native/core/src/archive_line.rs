//! One line of the archive log (SPEC §8.1, §8.2): a JSON object tagged by
//! `op`. The first line of a log is the header; every later one is a
//! commit.

use dsync_domain::{ArchiveCommit, ContentHash, FileMeta, FileState, RelPath};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "op", rename_all = "lowercase")]
pub(crate) enum Line {
    /// `version` is the log's format, `major.minor`
    /// ([`crate::ARCHIVE_FORMAT_VERSION`]).
    Header {
        version: String,
        #[serde(rename = "profileId")]
        profile_id: String,
        #[serde(rename = "rootPath")]
        root_path: String,
    },
    Upsert {
        path: String,
        size: u64,
        /// Microseconds since the epoch.
        mtime: i64,
        mode: u32,
        hash: String,
    },
    Delete {
        path: String,
    },
    Intent {
        path: String,
    },
    Withdraw {
        path: String,
    },
}

impl Line {
    pub(crate) fn of_commit(commit: &ArchiveCommit) -> Line {
        let path = commit.path().as_str().to_owned();
        match commit {
            ArchiveCommit::Upsert { file, .. } => Line::Upsert {
                path,
                size: file.meta.size,
                mtime: file.meta.mtime_us,
                mode: file.meta.mode,
                hash: file.hash.to_string(),
            },
            ArchiveCommit::Delete(_) => Line::Delete { path },
            ArchiveCommit::Intent(_) => Line::Intent { path },
            ArchiveCommit::Withdraw(_) => Line::Withdraw { path },
        }
    }

    /// The commit this line records, or why it records none.
    pub(crate) fn into_commit(self) -> Result<ArchiveCommit, String> {
        let parse_path = |path: &str| RelPath::parse(path).map_err(|error| error.to_string());
        Ok(match self {
            Line::Header { .. } => return Err("a second header".to_owned()),
            Line::Upsert {
                path,
                size,
                mtime,
                mode,
                hash,
            } => ArchiveCommit::Upsert {
                path: parse_path(&path)?,
                file: FileState {
                    meta: FileMeta {
                        size,
                        mtime_us: mtime,
                        mode,
                    },
                    hash: hash
                        .parse::<ContentHash>()
                        .map_err(|error| error.to_string())?,
                },
            },
            Line::Delete { path } => ArchiveCommit::Delete(parse_path(&path)?),
            Line::Intent { path } => ArchiveCommit::Intent(parse_path(&path)?),
            Line::Withdraw { path } => ArchiveCommit::Withdraw(parse_path(&path)?),
        })
    }

    /// Appends this line and its newline to `out`.
    pub(crate) fn write_to(&self, out: &mut Vec<u8>) {
        // Serializing a plain enum of strings and integers cannot fail.
        serde_json::to_writer(&mut *out, self).expect("archive line serializes");
        out.push(b'\n');
    }
}
