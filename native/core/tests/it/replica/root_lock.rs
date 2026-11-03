//! The lock file inside a replica's root (SPEC §4.3): what excludes a run
//! of another installation - another state directory - over the same
//! folder, which the state-dir locks cannot see.

use std::fs;
use std::path::{Path, PathBuf};

use dsync_core::{LocalReplica, LockError, Replica, ReplicaError, Root, StateDir, Symlinks};
use dsync_domain::{ArchiveFacts, EntryId, Jobs, RelPath, RootKind, RuleSet, Side, Tuning};

use crate::replica::child::{ChildProcess, READY, wait_for_parent};
use crate::replica::support::{PROFILE, Site, with_deadline};

/// Another installation on this host: its own state directory.
fn other_state(site: &Site) -> StateDir {
    StateDir::new(site.dir().join("other-state"))
}

fn installed(root: Root, state: StateDir) -> LocalReplica {
    LocalReplica::open(
        root,
        state,
        EntryId::parse(PROFILE).unwrap(),
        Side::A,
        Jobs::DEFAULT,
        Tuning::DEFAULT,
        Symlinks::AsRuled,
    )
}

fn folder(path: &Path) -> Root {
    Root::folder(path.to_str().unwrap().to_owned())
}

fn file_root(path: &Path) -> Root {
    let name = path.file_name().unwrap().to_str().unwrap();
    Root::new(
        path.to_str().unwrap().to_owned(),
        RootKind::File,
        Some(RelPath::parse(name).unwrap()),
    )
    .unwrap()
}

fn lock_file(site: &Site) -> PathBuf {
    site.root(Side::A).join(".dsync-lock")
}

/// The refusal of a root another installation's run holds, at `lock`;
/// the owner it names.
fn assert_root_in_use(result: Result<ArchiveFacts, ReplicaError>, lock: &Path) -> String {
    match result {
        Err(ReplicaError::Lock(LockError::RootInUse { lock: named, owner })) if named == lock => {
            owner
        }
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn a_run_from_another_state_dir_over_the_same_root_is_refused_by_the_root_lock() {
    let site = Site::new();
    let root = site.root(Side::A);
    let first = installed(folder(&root), site.state());
    let second = installed(folder(&root), other_state(&site));

    with_deadline("locks", async {
        first.lock().await.unwrap();
        let owner = assert_root_in_use(second.lock().await, &lock_file(&site));
        assert!(
            owner.contains(&format!("pid {}", std::process::id())),
            "{owner}"
        );
        assert!(
            owner.contains(site.state().path().to_str().unwrap()),
            "{owner}"
        );

        // The refusal left nothing of the second's held: once the first
        // lets go, it locks.
        first.unlock().await.unwrap();
        second.lock().await.unwrap();
        second.unlock().await.unwrap();
    })
    .await;
}

#[tokio::test]
async fn unlock_removes_the_root_lock_file_and_the_scan_never_reports_it() {
    let site = Site::new();
    let replica = site.replica(Side::A);

    let opened = with_deadline("lock and scan", async {
        replica.lock().await.unwrap();
        replica.open_scan(&RuleSet::default()).await.unwrap()
    })
    .await;
    let record = fs::read_to_string(lock_file(&site)).unwrap();
    assert!(
        record.contains(&format!("\"pid\":{}", std::process::id())),
        "{record}"
    );
    assert!(opened.changed.entries.is_empty(), "{:?}", opened.changed);

    with_deadline("unlock", replica.unlock()).await.unwrap();
    assert!(!lock_file(&site).exists());
}

#[tokio::test]
async fn a_root_lock_recorded_on_another_host_is_refused_until_it_is_deleted() {
    let site = Site::new();
    fs::write(
        lock_file(&site),
        r#"{"host":"elsewhere.invalid","boot":null,"pid":1,"state":"/far/state","started":0}"#,
    )
    .unwrap();
    let replica = site.replica(Side::A);

    let owner = assert_root_in_use(
        with_deadline("lock", replica.lock()).await,
        &lock_file(&site),
    );
    assert!(owner.contains("on host elsewhere.invalid"), "{owner}");
    assert!(owner.contains("/far/state"), "{owner}");
    // Refused, not taken over: the other host's record is still there.
    assert!(
        fs::read_to_string(lock_file(&site))
            .unwrap()
            .contains("elsewhere.invalid")
    );

    fs::remove_file(lock_file(&site)).unwrap();
    with_deadline("lock", replica.lock()).await.unwrap();
    with_deadline("unlock", replica.unlock()).await.unwrap();
}

#[test]
fn a_root_lock_left_by_a_killed_holder_on_this_host_is_taken_over() {
    let site = Site::new();
    let mut holder = ChildProcess::spawn("hold-root", site.dir());
    holder.wait_until_ready();
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let replica = site.replica(Side::A);
    assert_root_in_use(
        runtime.block_on(with_deadline("contended lock", replica.lock())),
        &lock_file(&site),
    );

    holder.kill();
    holder.wait();
    // Left behind, still naming the dead holder.
    let left = fs::read_to_string(lock_file(&site)).unwrap();
    assert!(
        !left.contains(&format!("\"pid\":{}", std::process::id())),
        "{left}"
    );

    runtime
        .block_on(with_deadline("lock", replica.lock()))
        .unwrap();
    let taken = fs::read_to_string(lock_file(&site)).unwrap();
    assert!(
        taken.contains(&format!("\"pid\":{}", std::process::id())),
        "{taken}"
    );
    runtime
        .block_on(with_deadline("unlock", replica.unlock()))
        .unwrap();
    assert!(!lock_file(&site).exists());
}

/// The child's side of
/// [`a_root_lock_left_by_a_killed_holder_on_this_host_is_taken_over`]:
/// side A's root locked from another state dir, held until killed.
pub fn hold_root(dir: &Path) {
    let site = Site::at(dir);
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let replica = installed(folder(&site.root(Side::A)), other_state(&site));
    runtime.block_on(replica.lock()).unwrap();
    println!("{READY}");
    wait_for_parent();
}

#[tokio::test]
async fn a_root_created_by_the_run_takes_its_root_lock_once_created() {
    let site = Site::new();
    let fresh = site.root(Side::A).join("not/yet");
    let first = installed(folder(&fresh), site.state());
    let second = installed(folder(&fresh), other_state(&site));

    with_deadline("lock and create", async {
        first.lock().await.unwrap();
        first.create_root().await.unwrap();
        assert_root_in_use(second.lock().await, &fresh.join(".dsync-lock"));
        first.unlock().await.unwrap();
    })
    .await;
    assert!(!fresh.join(".dsync-lock").exists());
}

#[tokio::test]
async fn a_folder_root_and_a_file_root_over_the_same_folder_lock_apart() {
    let site = Site::new();
    let notes = site.put(Side::A, "notes.md", "n");
    let whole = installed(folder(&site.root(Side::A)), site.state());
    let one_file = installed(file_root(&notes), other_state(&site));
    let same_file = installed(
        file_root(&notes),
        StateDir::new(site.dir().join("third-state")),
    );

    with_deadline("locks", async {
        whole.lock().await.unwrap();
        one_file.lock().await.unwrap();
        assert!(site.root(Side::A).join(".dsync-lock.notes.md").exists());
        // Positive control: the same file root from another installation
        // still meets the file root's own lock.
        assert_root_in_use(
            same_file.lock().await,
            &site.root(Side::A).join(".dsync-lock.notes.md"),
        );
        one_file.unlock().await.unwrap();
        whole.unlock().await.unwrap();
    })
    .await;
    assert!(!site.root(Side::A).join(".dsync-lock.notes.md").exists());
}
