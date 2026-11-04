//! Whether a profile's last run finished its apply, and what it was
//! writing if not (SPEC §7.6), as one file in the initiating host's state
//! directory: `<state>/<profileId>.run` ([`crate::StateDir::run_marker`]).
//!
//! Created before the apply writes anything, holding the side and path of
//! every write that apply set out to make ([`UnfinishedApply`], as JSON),
//! so the next run's reconcile can hold back a change found where a dead
//! write may have left damage. A run whose apply returns, failed actions
//! or not, rewrites it to the writes still held - not yet settled by a
//! later run - and deletes it once there are none. Which of the two wrote
//! it ([`MarkerRecord`]) is what tells a run that died from one that
//! finished with an earlier dead run's write still held. A file of its own
//! rather than something read out of the archive log, so "did the last run
//! finish?" costs one small read per profile, not a replay. Beside the
//! record it names the pair it is of ([`MarkerPair`]), so a marker no saved
//! profile claims - a run started without saving it - can still be shown.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use dsync_domain::{EffectiveOptions, EntryId, Side, UnfinishedApply};

use crate::atomic_write::write_atomically;
use crate::state_dir::{StateDir, run_marker_owner};

/// What a run marker holds.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum MarkerRecord {
    /// Written before an apply starts: its own writes beside every earlier
    /// one still held. Still there, that apply died.
    Applying(UnfinishedApply),
    /// Written once an apply returned: the writes an earlier dead apply
    /// made that no run has settled yet.
    Held(UnfinishedApply),
}

impl MarkerRecord {
    /// Every write the marker holds back, whichever run wrote it.
    pub fn into_writes(self) -> UnfinishedApply {
        match self {
            MarkerRecord::Applying(writes) | MarkerRecord::Held(writes) => writes,
        }
    }

    pub fn last_run(&self) -> LastRun {
        match self {
            MarkerRecord::Applying(_) => LastRun::Died,
            MarkerRecord::Held(_) => LastRun::WriteHeld,
        }
    }
}

/// What the last run of an entry left, as its marker says. Ordered by how
/// much it asks of the user, so a profile's entries report the greatest.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Default)]
pub enum LastRun {
    /// No marker: the last apply returned and holds nothing back.
    #[default]
    Settled,
    /// The last run finished, but a write an earlier run died making is
    /// still held back, as a conflict, until a run settles it.
    WriteHeld,
    /// The last run died mid-apply.
    Died,
}

/// The pair a marker is of: its two replicas as the run named them. An
/// entry id is a hash of the pair, so this is what a head can show for a
/// marker no saved profile's entry claims (task 75af93).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct MarkerPair {
    pub a: String,
    pub b: String,
}

impl MarkerPair {
    pub fn of(options: &EffectiveOptions) -> MarkerPair {
        MarkerPair {
            a: options.replica(Side::A).to_string(),
            b: options.replica(Side::B).to_string(),
        }
    }
}

/// A marker file's contents, as written.
#[derive(serde::Serialize)]
struct Storing<'a> {
    pair: &'a MarkerPair,
    record: &'a MarkerRecord,
}

/// A marker file's contents, as read.
#[derive(serde::Deserialize)]
struct Stored {
    pair: MarkerPair,
    record: MarkerRecord,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct RunMarker {
    path: PathBuf,
}

impl RunMarker {
    pub fn new(path: PathBuf) -> RunMarker {
        RunMarker { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Every marker in `state`, with the entry its file name says it is
    /// of; none when the directory does not exist.
    pub fn every(state: &StateDir) -> io::Result<Vec<(EntryId, RunMarker)>> {
        let entries = match fs::read_dir(state.path()) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        let mut markers = Vec::new();
        for entry in entries {
            let entry = entry?;
            let Some(entry_id) = entry.file_name().to_str().and_then(run_marker_owner) else {
                continue;
            };
            markers.push((entry_id, RunMarker::new(entry.path())));
        }
        Ok(markers)
    }

    /// What the last run left; an unreadable marker is an error.
    pub fn last_run(&self) -> io::Result<LastRun> {
        Ok(self
            .read()?
            .map_or(LastRun::Settled, |record| record.last_run()))
    }

    /// The marker's record; `None` when there is no marker. A record that
    /// does not parse - cut short as it was created, which is before the
    /// apply wrote anything - still says the run died, with no writes
    /// known.
    pub fn read(&self) -> io::Result<Option<MarkerRecord>> {
        Ok(self.bytes()?.map(|bytes| {
            serde_json::from_slice::<Stored>(&bytes).map_or_else(
                |_| MarkerRecord::Applying(UnfinishedApply::default()),
                |stored| stored.record,
            )
        }))
    }

    /// The pair the marker is of; `None` when there is no marker or it
    /// does not parse.
    pub fn pair(&self) -> io::Result<Option<MarkerPair>> {
        Ok(self
            .bytes()?
            .and_then(|bytes| serde_json::from_slice::<Stored>(&bytes).ok())
            .map(|stored| stored.pair))
    }

    fn bytes(&self) -> io::Result<Option<Vec<u8>>> {
        match fs::read(&self.path) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// Creates the marker holding `record` for `pair`, or replaces the one
    /// there, durably and atomically: staged, fsynced and renamed, the
    /// directory fsynced. A kill mid-write leaves the marker as it was,
    /// never a record cut short that would forget the writes it held.
    pub fn create(&self, pair: &MarkerPair, record: &MarkerRecord) -> io::Result<()> {
        let bytes = serde_json::to_vec(&Storing { pair, record }).map_err(io::Error::other)?;
        write_atomically(&self.path, &bytes)?;
        Ok(())
    }

    /// Removes the marker; one already gone is not an error.
    pub fn delete(&self) -> io::Result<()> {
        match fs::remove_file(&self.path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            other => other,
        }
    }
}
