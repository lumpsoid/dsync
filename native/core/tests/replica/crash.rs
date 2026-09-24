//! A crash between the two per-path commits a copy makes (SPEC §7.3,
//! §14; Dart's `crash_safety_test`): the next run must neither lose the
//! copy nor move its bytes again.

use dsync_core::Replica;
use dsync_domain::{Action, Side, Status};

use crate::support::{CopyUntil, Site, apply, copy, exchange, hash_of, path, seed, with_deadline};

#[tokio::test]
async fn a_crash_between_the_two_commits_converges_without_moving_bytes_again() {
    let site = Site::new();
    site.put(Side::A, "f", "v1");
    site.put(Side::B, "f", "v1");
    {
        let a = site.replica(Side::A);
        let b = site.replica(Side::B);
        with_deadline("seed", async {
            seed(&a).await;
            seed(&b).await;
        })
        .await;
    }
    site.put(Side::A, "f", "version two");

    // The run that crashes: B's commit lands, A's never happens.
    {
        let a = site.replica(Side::A);
        let b = site.replica(Side::B);
        with_deadline("crashing run", async {
            let exchanged = exchange(&a, &b).await;
            assert_eq!(
                exchanged.plan.actions,
                [Action::Copy {
                    path: path("f"),
                    from: Side::A,
                    bytes: 11,
                }]
            );
            let source = *exchanged.status(Side::A, "f").unwrap().file().unwrap();
            copy(&a, &b, "f", source, CopyUntil::DestinationCommitted).await;
            a.unlock().await.unwrap();
            b.unlock().await.unwrap();
        })
        .await;
    }
    assert_eq!(site.get(Side::B, "f"), b"version two");
    assert_eq!(
        site.archive(Side::B).get(&path("f")).map(|f| f.hash),
        Some(hash_of("version two"))
    );
    assert_eq!(
        site.archive(Side::A).get(&path("f")).map(|f| f.hash),
        Some(hash_of("v1"))
    );

    // The next run: A reports modified, B unchanged, with the same content
    // - commit-only, not a second copy.
    let a = site.replica(Side::A);
    let b = site.replica(Side::B);
    let before = site.state_of(Side::B, "f");
    with_deadline("recovery run", async {
        let exchanged = exchange(&a, &b).await;
        assert!(matches!(
            exchanged.status(Side::A, "f"),
            Some(Status::Modified(_))
        ));
        assert!(matches!(
            exchanged.status(Side::B, "f"),
            Some(Status::Unchanged { .. })
        ));
        assert!(exchanged.plan.conflicts.is_empty());
        assert_eq!(
            exchanged.plan.actions,
            [Action::CommitOnly { path: path("f") }]
        );
        apply(&a, &b, &exchanged).await;
    })
    .await;

    assert_eq!(site.state_of(Side::B, "f"), before, "B's bytes never moved");
    for side in [Side::A, Side::B] {
        assert_eq!(
            site.archive(side).get(&path("f")),
            Some(&site.state_of(side, "f")),
            "{side}'s archive matches its disk"
        );
    }
    let settled = with_deadline("settled run", exchange(&a, &b)).await;
    assert!(settled.plan.actions.is_empty());
    assert!(settled.plan.conflicts.is_empty());
}
