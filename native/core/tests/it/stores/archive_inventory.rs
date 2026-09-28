//! The cases of `test/dsync_core/archive/archive_inventory_test.dart`.

use std::fs;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use dsync_core::{
    ArchiveDeleteError, ArchiveHeader, ArchiveInventory, ArchiveStore, LockError, ReplicaLock,
    StateDir,
};
use dsync_domain::{EntryId, Side, Tuning};
use tempfile::TempDir;

use crate::stores::support::{file, names_in, upsert};

const P1: &str = "11111111111111111111111111111111";
const P2: &str = "22222222222222222222222222222222";
const P3: &str = "33333333333333333333333333333333";

fn id(text: &str) -> EntryId {
    EntryId::parse(text).unwrap()
}

struct Fixture {
    dir: TempDir,
}

impl Fixture {
    fn new() -> Fixture {
        Fixture {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    fn state(&self) -> StateDir {
        StateDir::new(self.dir.path())
    }

    fn inventory(&self) -> ArchiveInventory {
        ArchiveInventory::new(self.state())
    }

    /// A real log, written by the real store.
    fn write_log(&self, profile: &str, side: Side, root: &str, entries: usize) -> PathBuf {
        let mut store = ArchiveStore::open_replica(
            &self.state(),
            &id(profile),
            side,
            root.into(),
            &Tuning::DEFAULT,
        )
        .unwrap();
        store
            .commit((0..entries).map(|i| upsert(&format!("file{i}.txt"), file(10, 1))))
            .unwrap();
        store.flush().unwrap();
        self.state().archive_log(&id(profile), side)
    }

    fn set_mtime(&self, log: &PathBuf, seconds: u64) {
        fs::File::options()
            .write(true)
            .open(log)
            .unwrap()
            .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds))
            .unwrap();
    }
}

#[test]
fn reports_every_log_with_its_replica_root_size_and_mtime() {
    let fixture = Fixture::new();
    let log = fixture.write_log(P1, Side::A, "/home/me/notes", 1);
    fixture.write_log(P1, Side::B, "/media/phone/notes", 2);

    let listed = fixture.inventory().list().unwrap();
    assert_eq!(listed.len(), 2);
    let a = listed.iter().find(|stored| stored.side == Side::A).unwrap();
    assert_eq!(a.log_path, log);
    assert_eq!(a.entry_id, id(P1));
    assert_eq!(a.root_path.as_deref(), Some("/home/me/notes"));
    let metadata = fs::metadata(&log).unwrap();
    assert_eq!(a.size_bytes, metadata.len());
    assert_eq!(a.last_modified, metadata.modified().unwrap());
    let b = listed.iter().find(|stored| stored.side == Side::B).unwrap();
    assert_eq!(b.root_path.as_deref(), Some("/media/phone/notes"));
}

#[test]
fn lists_a_log_whose_header_cannot_be_read_with_no_root() {
    let fixture = Fixture::new();
    fs::write(
        fixture.dir.path().join(format!("{P3}-a.jsonl")),
        "not json\n",
    )
    .unwrap();
    fs::write(
        fixture.dir.path().join(format!("{P2}-b.jsonl")),
        "{\"op\":\"upsert\",\"path\":\"a.txt\"}\n",
    )
    .unwrap();
    fs::write(fixture.dir.path().join(format!("{P1}-a.jsonl")), "").unwrap();

    let listed = fixture.inventory().list().unwrap();
    assert_eq!(listed.len(), 3);
    assert!(listed.iter().all(|stored| stored.root_path.is_none()));
}

#[test]
fn lists_a_log_of_another_major_with_its_root_so_it_can_be_cleared() {
    let fixture = Fixture::new();
    fs::write(
        fixture.dir.path().join(format!("{P1}-a.jsonl")),
        "{\"op\":\"header\",\"version\":\"2.0\",\"entry_id\":\"notes\",\"rootPath\":\"/old\"}\n",
    )
    .unwrap();

    let listed = fixture.inventory().list().unwrap();
    assert_eq!(listed[0].root_path.as_deref(), Some("/old"));
}

#[test]
fn ignores_everything_in_the_directory_that_is_not_a_log() {
    let fixture = Fixture::new();
    let log = fixture.write_log(P1, Side::A, "/home/me/notes", 1);
    let dir = fixture.dir.path();
    for other in [
        format!("{P1}-a.lock"),
        format!("{P1}.run"),
        format!("{P1}-a.jsonl.dsync-tmp.12.0"),
        format!("{P1}.jsonl"),
        format!("{P1}-c.jsonl"),
        "notes-a.jsonl".to_owned(),
        "identity.crt".to_owned(),
        "paired-devices.json".to_owned(),
    ] {
        fs::write(dir.join(other), "").unwrap();
    }
    fs::create_dir(dir.join(format!("{P2}-a.jsonl"))).unwrap();

    let listed = fixture.inventory().list().unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].log_path, log);
}

#[test]
fn a_state_directory_that_does_not_exist_is_an_empty_list() {
    let fixture = Fixture::new();
    let missing = ArchiveInventory::new(StateDir::new(fixture.dir.path().join("never")));
    assert!(missing.list().unwrap().is_empty());
}

#[test]
fn lists_newest_written_first() {
    let fixture = Fixture::new();
    let old = fixture.write_log(P1, Side::A, "/r1", 1);
    let new = fixture.write_log(P2, Side::A, "/r2", 1);
    let middle = fixture.write_log(P3, Side::A, "/r3", 1);
    fixture.set_mtime(&old, 1_000);
    fixture.set_mtime(&middle, 2_000);
    fixture.set_mtime(&new, 3_000);

    let order: Vec<PathBuf> = fixture
        .inventory()
        .list()
        .unwrap()
        .into_iter()
        .map(|stored| stored.log_path)
        .collect();
    assert_eq!(order, [new, middle, old]);
}

#[test]
fn deleting_removes_the_log_and_nothing_else() {
    let fixture = Fixture::new();
    let log = fixture.write_log(P1, Side::A, "/home/me/notes", 1);
    let neighbour = fixture.write_log(P2, Side::A, "/home/me/pics", 1);
    let other_side = fixture.write_log(P1, Side::B, "/phone/notes", 1);

    fixture.inventory().delete(&id(P1), Side::A).unwrap();

    assert!(!log.exists());
    assert!(neighbour.exists());
    assert!(other_side.exists());
    let left: Vec<EntryId> = fixture
        .inventory()
        .list()
        .unwrap()
        .into_iter()
        .map(|stored| stored.entry_id)
        .collect();
    assert_eq!(left.len(), 2);
    assert!(!names_in(fixture.dir.path()).contains(&format!("{P1}-a.jsonl")));
}

#[test]
fn deleting_is_refused_while_a_run_holds_the_replica() {
    let fixture = Fixture::new();
    let log = fixture.write_log(P1, Side::A, "/home/me/notes", 1);
    // What a run takes for its length - here, in this process, as the
    // head's own run would.
    let run = ReplicaLock::acquire(&fixture.state().lock(&id(P1), Side::A)).unwrap();

    let refused = fixture.inventory().delete(&id(P1), Side::A);
    assert!(
        matches!(
            refused,
            Err(ArchiveDeleteError::Lock(LockError::Held { .. }))
        ),
        "{refused:?}"
    );
    assert!(log.exists());

    // And deletable the moment the run is done with it.
    drop(run);
    fixture.inventory().delete(&id(P1), Side::A).unwrap();
    assert!(!log.exists());
}

#[test]
fn deleting_a_log_that_is_already_gone_is_not_an_error() {
    let fixture = Fixture::new();
    fixture.inventory().delete(&id(P1), Side::B).unwrap();
}

#[test]
fn the_next_run_over_a_deleted_archive_starts_from_nothing() {
    let fixture = Fixture::new();
    fixture.write_log(P1, Side::A, "/home/me/notes", 3);

    fixture.inventory().delete(&id(P1), Side::A).unwrap();

    let header = ArchiveHeader {
        entry_id: id(P1),
        root_path: "/home/me/notes".into(),
    };
    let next = ArchiveStore::open(
        fixture.state().archive_log(&id(P1), Side::A),
        header,
        &Tuning::DEFAULT,
    )
    .unwrap();
    assert!(next.archive().is_empty());
}
