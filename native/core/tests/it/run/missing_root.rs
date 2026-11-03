//! SPEC §4.5 through a run, with side B local and served over the
//! protocol: the cases of `missing_root_test.dart`.

use std::fs;
use std::sync::Arc;

use dsync_core::{BatchDecider, Replica, RunError};
use dsync_domain::{ArchiveCommit, ContentHash, FileMeta, FileState, Side};
use tokio::sync::{Notify, Semaphore};

use crate::run::support::{Call, Fault, Finished, Probe, Site, path, run, served, with_deadline};

#[derive(Clone, Copy, Debug)]
enum Reach {
    Local,
    Served,
}

async fn sync_over(site: &Site, reach: Reach) -> Finished {
    match reach {
        Reach::Local => {
            run(
                site,
                site.replica(Side::A),
                site.replica(Side::B),
                &mut BatchDecider,
            )
            .await
        }
        Reach::Served => {
            let (b, serving) = served(site, Side::B).await;
            let finished = run(site, site.replica(Side::A), b, &mut BatchDecider).await;
            with_deadline("the session's end", serving)
                .await
                .unwrap()
                .unwrap();
            finished
        }
    }
}

async fn first_sync_creates_the_missing_root(reach: Reach) {
    let site = Site::new();
    fs::remove_dir(site.root(Side::B)).unwrap();
    site.put(Side::A, "notes/n.txt", "n");

    let finished = sync_over(&site, reach).await;

    assert_eq!(
        finished.exit_code(),
        0,
        "{reach:?}: {:?}",
        finished.errors()
    );
    assert_eq!(site.get(Side::B, "notes/n.txt").unwrap(), b"n");
}

async fn a_removed_root_is_refused_by_name(reach: Reach) {
    let site = Site::new();
    site.put(Side::A, "one", "1");
    site.put(Side::A, "two", "2");
    assert_eq!(sync_over(&site, reach).await.exit_code(), 0);
    fs::remove_dir_all(site.root(Side::B)).unwrap();
    let before = site.tree(Side::A);

    let finished = sync_over(&site, reach).await;

    let [RunError::MissingRoot(missing)] = finished.errors()[..] else {
        panic!("{reach:?}: {:?}", finished.errors());
    };
    assert_eq!(missing.side, Side::B);
    assert_eq!(missing.archived_files, 2);
    assert_eq!(missing.root_path, site.root(Side::B).to_str().unwrap());
    assert_eq!(finished.exit_code(), 3);
    assert_eq!(site.tree(Side::A), before);
    assert!(!site.root(Side::B).exists());
}

async fn a_refusal_of_one_side_does_not_create_the_other(reach: Reach) {
    let site = Site::new();
    site.put(Side::B, "kept", "k");
    // B syncs once against a scratch A, so B has an archive and A none.
    assert_eq!(sync_over(&site, reach).await.exit_code(), 0);
    fs::remove_dir_all(site.root(Side::A)).unwrap();
    let archive_a = site.log(Side::A);
    if archive_a.exists() {
        fs::remove_file(archive_a).unwrap();
    }
    fs::remove_dir_all(site.root(Side::B)).unwrap();

    let finished = sync_over(&site, reach).await;

    assert!(matches!(
        finished.errors()[..],
        [RunError::MissingRoot(missing)] if missing.side == Side::B
    ));
    assert!(!site.root(Side::A).exists(), "A would have been created");
}

#[tokio::test]
async fn a_first_sync_into_a_missing_root_creates_it_and_completes() {
    for reach in [Reach::Local, Reach::Served] {
        first_sync_creates_the_missing_root(reach).await;
    }
}

#[tokio::test]
async fn a_later_sync_with_the_root_removed_refuses_by_name_and_changes_nothing() {
    for reach in [Reach::Local, Reach::Served] {
        a_removed_root_is_refused_by_name(reach).await;
    }
}

#[tokio::test]
async fn a_refusal_of_one_side_does_not_create_the_other_sides_root() {
    for reach in [Reach::Local, Reach::Served] {
        a_refusal_of_one_side_does_not_create_the_other(reach).await;
    }
}

#[tokio::test]
async fn the_missing_root_rule_judges_the_archive_as_the_lock_read_it() {
    let site = Site::new();
    fs::remove_dir(site.root(Side::B)).unwrap();
    let (locking, gate) = (Arc::new(Notify::new()), Arc::new(Semaphore::new(0)));
    let (b, _) = Probe::with_hook(site.replica(Side::B), {
        let (locking, gate) = (locking.clone(), gate.clone());
        Arc::new(move |call: &Call| {
            (*call == Call::Lock).then(|| {
                locking.notify_one();
                Fault::Hold(gate.clone())
            })
        })
    });
    // Between B's hello, when its archive was empty, and its lock, another
    // run on B commits: from then on B has synced before.
    let committing = async {
        locking.notified().await;
        let other = site.replica(Side::B);
        other.lock().await.unwrap();
        let file = FileState {
            meta: FileMeta {
                size: 1,
                mtime_us: 1,
                mode: 0o644,
                read_us: 1_700_000_000_000_000,
            },
            hash: ContentHash::from_digest([1; 32]),
        };
        other
            .commit(vec![ArchiveCommit::Upsert {
                path: path("f"),
                file,
            }])
            .await
            .unwrap();
        other.unlock().await.unwrap();
        gate.close();
    };

    let mut decider = BatchDecider;
    let (finished, ()) = tokio::join!(
        run(&site, site.replica(Side::A), b, &mut decider),
        committing
    );

    let [RunError::MissingRoot(missing)] = finished.errors()[..] else {
        panic!("{:?}", finished.errors());
    };
    assert_eq!((missing.side, missing.archived_files), (Side::B, 1));
    assert!(!site.root(Side::B).exists(), "created from stale facts");
}
