//! A single-file root (plan D8): its replica reaches exactly its one file,
//! whatever path it is asked for - locally and served, where the dialer
//! chooses the paths - and reports its root as present, parent-missing or
//! the wrong kind at `hello`.

use std::fs;
use std::path::{Path, PathBuf};

use dsync_core::{
    Body, LocalReplica, RemoteReplica, Replica, ReplicaServer, Root, Symlinks, Transport,
};
use dsync_domain::{
    ArchiveCommit, EntryId, Glob, Jobs, Precondition, ReplicaRoot, ReplicaSpec, RootKind, RuleSet,
    Side, SkippedReason, Status, Tuning,
};

use crate::replica::served::open_local;
use crate::replica::support::{PROFILE, Site, expect_at, meta, path, recorded, with_deadline};

/// The name the entry syncs its file under (side A's); side B's own file
/// is `mine.md`.
const AS_PATH: &str = "notes.md";

fn spec(file: &Path) -> ReplicaSpec {
    ReplicaSpec {
        root: file.to_str().unwrap().to_owned(),
        kind: RootKind::File,
        as_path: Some(path(AS_PATH)),
        entry: EntryId::parse(PROFILE).unwrap(),
        side: Side::B,
        jobs: Jobs::DEFAULT,
    }
}

fn local(site: &Site, file: &Path) -> LocalReplica {
    let spec = spec(file);
    LocalReplica::open(
        Root::new(spec.root, spec.kind, spec.as_path).unwrap(),
        site.state(),
        spec.entry,
        spec.side,
        spec.jobs,
        Tuning::DEFAULT,
        Symlinks::AsRuled,
    )
    .unwrap()
}

/// The file root at `file`, served over the protocol: what the dialer
/// sends is all the far side acts on.
async fn served(site: &Site, file: &Path) -> RemoteReplica {
    let server = ReplicaServer::new(open_local(site.state()), Tuning::DEFAULT);
    let (near, far) = tokio::io::duplex(64 * 1024);
    tokio::spawn(async move { server.serve(Transport::split(far)).await });
    let replica = with_deadline(
        "connect",
        RemoteReplica::connect(Transport::split(near), spec(file), &Tuning::DEFAULT),
    )
    .await
    .unwrap();
    // The far side opens the replica at the first `hello`.
    replica.hello().await.unwrap();
    replica
}

#[derive(Clone, Copy, Debug)]
enum Reach {
    Local,
    Served,
}

/// Side B's folder: its own file, a sibling, and a file one folder down.
fn folder(site: &Site) -> (PathBuf, PathBuf) {
    let mine = site.put(Side::B, "mine.md", "mine");
    site.put(Side::B, "sibling.md", "secret");
    site.put(Side::B, "sub/notes.md", "deep");
    fs::create_dir(site.file(Side::B, "empty")).unwrap();
    (site.root(Side::B), mine)
}

async fn write(
    replica: &impl Replica,
    relative: &str,
    content: &str,
    expect: Precondition,
) -> bool {
    with_deadline(
        "write",
        replica.write(
            &path(relative),
            Body::from_bytes(content.as_bytes().to_vec()),
            meta(0o644),
            expect,
        ),
    )
    .await
    .is_ok()
}

/// Every path but the synced name is refused, for every operation that
/// touches the disk or the archive.
async fn refuses_all_but_its_own(replica: &impl Replica, site: &Site, reach: Reach) {
    let dir = site.root(Side::B);
    for other in [
        "sibling.md",
        "mine.md",
        "sub/notes.md",
        "notes.md/x",
        "new.md",
    ] {
        let at = path(other);
        assert!(replica.read(&at).await.is_err(), "{reach:?} read {other}");
        assert!(
            !write(replica, other, "evil", expect_at(&dir.join(other))).await,
            "{reach:?} write {other}"
        );
        assert!(
            replica
                .delete(&at, expect_at(&dir.join(other)))
                .await
                .is_err(),
            "{reach:?} delete {other}"
        );
        assert!(
            replica
                .commit(vec![ArchiveCommit::Upsert {
                    path: at.clone(),
                    file: recorded("evil"),
                }])
                .await
                .is_err(),
            "{reach:?} commit {other}"
        );
    }
    assert!(
        replica.remove_empty_dirs(&path("empty/x")).await.is_err(),
        "{reach:?}"
    );
    assert_eq!(site.get(Side::B, "sibling.md"), b"secret", "{reach:?}");
    assert_eq!(site.get(Side::B, "mine.md"), b"mine", "{reach:?}");
    assert_eq!(site.get(Side::B, "sub/notes.md"), b"deep", "{reach:?}");
    assert!(!site.file(Side::B, "new.md").exists(), "{reach:?}");
    assert!(site.file(Side::B, "empty").is_dir(), "{reach:?}");
}

/// Positive control: the synced name reaches the file, under its own name.
async fn serves_its_own(replica: &impl Replica, site: &Site, mine: &Path, reach: Reach) {
    let reading = replica.read(&path(AS_PATH)).await.unwrap();
    let mut body = reading.body;
    let mut read = Vec::new();
    while let Some(chunk) = body.next().await.unwrap() {
        read.extend(chunk);
    }
    assert_eq!(read, b"mine", "{reach:?}");
    assert!(
        write(replica, AS_PATH, "new", expect_at(mine)).await,
        "{reach:?}"
    );
    assert_eq!(fs::read(mine).unwrap(), b"new", "{reach:?}");
    replica
        .commit(vec![ArchiveCommit::Upsert {
            path: path(AS_PATH),
            file: recorded("new"),
        }])
        .await
        .unwrap();
    replica
        .delete(&path(AS_PATH), expect_at(mine))
        .await
        .unwrap();
    replica.remove_empty_dirs(&path(AS_PATH)).await.unwrap();
    assert!(!mine.exists(), "{reach:?}");
    assert!(site.root(Side::B).is_dir(), "{reach:?}");
}

#[tokio::test]
async fn a_file_root_refuses_every_path_but_its_synced_name_local_and_served() {
    for reach in [Reach::Local, Reach::Served] {
        let site = Site::new();
        let (_, mine) = folder(&site);
        match reach {
            Reach::Local => {
                let replica = local(&site, &mine);
                refuses_all_but_its_own(&replica, &site, reach).await;
                serves_its_own(&replica, &site, &mine, reach).await;
            }
            Reach::Served => {
                let replica = served(&site, &mine).await;
                refuses_all_but_its_own(&replica, &site, reach).await;
                serves_its_own(&replica, &site, &mine, reach).await;
                with_deadline("close", replica.close()).await.unwrap();
            }
        }
    }
}

#[tokio::test]
async fn deleting_the_only_file_leaves_its_folder() {
    let site = Site::new();
    let mine = site.put(Side::B, "mine.md", "mine");
    let replica = local(&site, &mine);

    replica
        .delete(&path(AS_PATH), expect_at(&mine))
        .await
        .unwrap();
    replica.remove_empty_dirs(&path(AS_PATH)).await.unwrap();

    assert!(!mine.exists());
    assert!(site.root(Side::B).is_dir());
}

#[tokio::test]
async fn hello_finds_the_file_root_present_even_without_its_file() {
    let site = Site::new();
    let replica = local(&site, &site.file(Side::B, "mine.md"));

    let info = replica.hello().await.unwrap();

    assert_eq!(info.root, ReplicaRoot::Present);
}

#[tokio::test]
async fn hello_reports_a_file_roots_missing_folder_and_a_folder_in_its_place() {
    let site = Site::new();
    let gone = site.file(Side::B, "gone/mine.md");
    let parent_missing = local(&site, &gone).hello().await.unwrap();
    assert_eq!(
        parent_missing.root,
        ReplicaRoot::ParentMissing {
            root_path: gone.to_str().unwrap().to_owned(),
            folder: site.file(Side::B, "gone").to_str().unwrap().to_owned(),
        }
    );

    let folder = site.file(Side::B, "mine.md");
    fs::create_dir(&folder).unwrap();
    let wrong = local(&site, &folder).hello().await.unwrap();
    assert_eq!(
        wrong.root,
        ReplicaRoot::WrongKind {
            root_path: folder.to_str().unwrap().to_owned(),
            expected: RootKind::File,
        }
    );
}

#[tokio::test]
async fn a_file_root_is_never_created() {
    let site = Site::new();
    let gone = site.file(Side::B, "gone/mine.md");

    assert!(local(&site, &gone).create_root().await.is_err());

    assert!(!site.file(Side::B, "gone").exists());
}

#[tokio::test]
async fn the_scan_reports_the_file_at_its_synced_name_whatever_the_rules_say() {
    let site = Site::new();
    let (_, mine) = folder(&site);
    let replica = local(&site, &mine);
    let rules = RuleSet::new(vec![Glob::new("*.md").unwrap()], vec![]);

    let scan = replica.open_scan(&rules).await.unwrap().changed;

    let paths: Vec<&str> = scan.entries.iter().map(|e| e.path.as_str()).collect();
    assert_eq!(paths, [AS_PATH]);
    assert!(scan.skipped.is_empty(), "{:?}", scan.skipped);
    // No probe is left beside the file.
    let mut left: Vec<String> = fs::read_dir(site.root(Side::B))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    left.sort();
    assert_eq!(left, ["empty", "mine.md", "sibling.md", "sub"]);
}

#[tokio::test]
async fn an_absent_file_whose_folder_is_there_scans_as_deleted() {
    let site = Site::new();
    let mine = site.file(Side::B, "mine.md");
    let replica = local(&site, &mine);
    replica
        .commit(vec![ArchiveCommit::Upsert {
            path: path(AS_PATH),
            file: recorded("old"),
        }])
        .await
        .unwrap();

    let scan = replica
        .open_scan(&RuleSet::default())
        .await
        .unwrap()
        .changed;

    assert_eq!(scan.entries.len(), 1);
    assert_eq!(scan.entries[0].path.as_str(), AS_PATH);
    assert_eq!(scan.entries[0].status, Status::Deleted);
}

#[cfg(unix)]
#[tokio::test]
async fn an_unreadable_file_is_reported_unreadable_not_deleted() {
    use crate::replica::support::set_mode;

    let site = Site::new();
    let mine = site.put(Side::B, "mine.md", "mine");
    let replica = local(&site, &mine);
    replica
        .commit(vec![ArchiveCommit::Upsert {
            path: path(AS_PATH),
            file: recorded("old"),
        }])
        .await
        .unwrap();
    set_mode(&mine, 0o000);
    // Root reads anything: the permission is not binding there.
    let binding = fs::File::open(&mine).is_err();

    let scan = replica
        .open_scan(&RuleSet::default())
        .await
        .unwrap()
        .changed;

    set_mode(&mine, 0o644);
    if !binding {
        return;
    }
    assert!(
        scan.entries.iter().all(|e| e.status != Status::Deleted),
        "{:?}",
        scan.entries
    );
    let [skipped] = &scan.skipped[..] else {
        panic!("{:?}", scan.skipped);
    };
    assert_eq!(skipped.path().map(|p| p.as_str()), Some(AS_PATH));
    assert_eq!(skipped.reason, SkippedReason::Unreadable);
}

#[cfg(unix)]
#[tokio::test]
async fn a_file_that_cannot_be_statted_is_reported_unreadable_not_deleted() {
    use crate::replica::support::set_mode;

    let site = Site::new();
    let mine = site.put(Side::B, "locked/mine.md", "mine");
    let replica = local(&site, &mine);
    replica
        .commit(vec![ArchiveCommit::Upsert {
            path: path(AS_PATH),
            file: recorded("mine"),
        }])
        .await
        .unwrap();
    let locked = site.file(Side::B, "locked");
    set_mode(&locked, 0o000);
    // Root stats anything: the permission is not binding there.
    let binding = fs::metadata(&mine).is_err();

    let scan = replica.open_scan(&RuleSet::default()).await;

    set_mode(&locked, 0o755);
    if !binding {
        return;
    }
    let scan = scan.unwrap().changed;
    assert!(scan.entries.is_empty(), "{:?}", scan.entries);
    let [skipped] = &scan.skipped[..] else {
        panic!("{:?}", scan.skipped);
    };
    assert_eq!(skipped.path().map(|p| p.as_str()), Some(AS_PATH));
    assert_eq!(skipped.reason, SkippedReason::Unreadable);
}
