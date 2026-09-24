//! SPEC §4.5 through a run, with side B local and served over the
//! protocol: the cases of `missing_root_test.dart`.

use std::fs;

use dsync_core::{BatchDecider, RunError};
use dsync_domain::Side;

use crate::support::{Finished, Site, run, served, with_deadline};

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
