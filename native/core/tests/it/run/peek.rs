//! A decider reading both replicas' current files while it reviews the
//! plan: what it sees, what it is refused unread, and what it leaves alone.

use dsync_core::{Compared, Decider, Peek, Replica, RunEvent};
use dsync_domain::{
    Action, Comparison, FileText, MassDelete, PeekLimits, Plan, RelPath, ReplicaOp, Side, Sided,
    Tuning,
};

use crate::run::support::{Finished, Site, path, run, run_with, served, sync, with_deadline};

/// A decider that changes the site after the scan, then peeks at each
/// comparison `compare` draws from the plan, `times` times each.
struct Peeking {
    /// What changes between the scan and the peeks.
    edit: Box<dyn FnMut() + Send>,
    compare: fn(&Plan) -> Vec<Comparison>,
    times: usize,
    /// Whether to approve the plan's actions.
    approve: bool,
    seen: Vec<(RelPath, Compared)>,
}

impl Peeking {
    fn new(edit: impl FnMut() + Send + 'static) -> Peeking {
        Peeking {
            edit: Box::new(edit),
            compare: copies,
            times: 1,
            approve: false,
            seen: Vec::new(),
        }
    }

    /// What it saw of `at`, the one time it looked.
    fn saw(&self, at: &str) -> &Compared {
        let mut seen = self.seen.iter().filter(|(p, _)| *p == path(at));
        let (_, compared) = seen.next().unwrap_or_else(|| panic!("{at} not peeked"));
        assert!(seen.next().is_none(), "{at} peeked more than once");
        compared
    }
}

impl Decider for Peeking {
    async fn decide<A: Replica, B: Replica>(
        &mut self,
        plan: &Plan,
        peek: Peek<'_, A, B>,
    ) -> Vec<Action> {
        (self.edit)();
        for comparison in (self.compare)(plan) {
            for _ in 0..self.times {
                let compared = peek.compare(&comparison).await;
                self.seen.push((comparison.path.clone(), compared));
            }
        }
        if self.approve {
            plan.actions.iter().map(|p| p.action.clone()).collect()
        } else {
            Vec::new()
        }
    }

    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        false
    }
}

/// Every copy the plan proposes, as its review row compares it.
fn copies(plan: &Plan) -> Vec<Comparison> {
    plan.actions
        .iter()
        .filter_map(Comparison::of_proposal)
        .collect()
}

fn text(content: &str) -> Option<FileText> {
    Some(FileText::decode(content.as_bytes().to_vec()).unwrap())
}

fn summarized(finished: &Finished) -> bool {
    finished
        .events
        .iter()
        .any(|e| matches!(e, RunEvent::Summary(_)))
}

#[tokio::test]
async fn a_peek_over_local_replicas_sees_an_edit_made_after_the_scan() {
    let site = Site::new();
    site.put(Side::A, "notes.txt", "one");
    sync(&site).await;
    site.put(Side::A, "notes.txt", "two!!");
    site.put(Side::A, "fresh.txt", "brand new");
    let notes = site.file(Side::A, "notes.txt");
    let mut peeking = Peeking::new(move || std::fs::write(&notes, "three after scan").unwrap());

    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut peeking,
    )
    .await;

    assert!(summarized(&finished));
    assert_eq!(
        peeking.saw("notes.txt"),
        &Compared::Texts {
            old: text("one"),
            new: text("three after scan"),
        }
    );
    // No file on the copy's destination: nothing is read there.
    assert_eq!(
        peeking.saw("fresh.txt"),
        &Compared::Texts {
            old: None,
            new: text("brand new"),
        }
    );
}

#[tokio::test]
async fn a_peek_over_a_served_replica_sees_an_edit_made_after_the_scan() {
    let site = Site::new();
    site.put(Side::B, "notes.txt", "one");
    sync(&site).await;
    site.put(Side::B, "notes.txt", "two!!");
    let notes = site.file(Side::B, "notes.txt");
    let mut peeking = Peeking::new(move || std::fs::write(&notes, "three after scan").unwrap());
    let (b, serving) = served(&site, Side::B).await;

    let finished = run(&site, site.replica(Side::A), b, &mut peeking).await;
    with_deadline("the session's end", serving)
        .await
        .unwrap()
        .unwrap();

    assert!(summarized(&finished));
    assert_eq!(
        peeking.saw("notes.txt"),
        &Compared::Texts {
            old: text("one"),
            new: text("three after scan"),
        }
    );
}

#[tokio::test]
async fn a_file_deleted_since_the_scan_is_unreadable_and_the_run_completes() {
    let site = Site::new();
    let gone = site.put(Side::A, "gone.txt", "here at the scan");
    let mut peeking = Peeking::new(move || std::fs::remove_file(&gone).unwrap());

    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut peeking,
    )
    .await;

    assert!(
        matches!(
            peeking.saw("gone.txt"),
            Compared::Unreadable { side: Side::A, message } if !message.is_empty()
        ),
        "{:?}",
        peeking.saw("gone.txt")
    );
    assert!(summarized(&finished));
}

#[tokio::test]
async fn a_file_grown_past_the_cap_since_the_scan_is_too_large_and_one_at_the_cap_is_read() {
    let site = Site::new();
    let grown = site.put(Side::A, "grown.txt", "small");
    let edge = site.put(Side::A, "edge.txt", "small");
    let mut peeking = Peeking::new(move || {
        std::fs::write(&grown, "0123456789+").unwrap();
        std::fs::write(&edge, "0123456789").unwrap();
    });
    let tuning = Tuning {
        peek: PeekLimits {
            max_bytes: 10,
            ..Tuning::DEFAULT.peek
        },
        ..Tuning::DEFAULT
    };

    run_with(
        &site,
        site.replica_with(Side::A, tuning),
        site.replica_with(Side::B, tuning),
        &site.options(),
        &mut peeking,
        tuning,
    )
    .await;

    assert_eq!(
        peeking.saw("grown.txt"),
        &Compared::TooLarge {
            side: Side::A,
            size: 11,
        }
    );
    assert_eq!(
        peeking.saw("edge.txt"),
        &Compared::Texts {
            old: None,
            new: text("0123456789"),
        }
    );
}

#[tokio::test]
async fn peeks_leave_the_read_metrics_to_the_apply() {
    let site = Site::new();
    site.put(Side::A, "f.txt", "copied once");
    let reads = |finished: &Finished| {
        finished
            .report
            .metrics
            .a
            .ops
            .get(&ReplicaOp::Read)
            .map_or(0, |op| op.count)
    };

    let mut only_peeking = Peeking {
        times: 3,
        ..Peeking::new(|| {})
    };
    let peeked = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut only_peeking,
    )
    .await;
    let mut applying = Peeking {
        times: 3,
        approve: true,
        ..Peeking::new(|| {})
    };
    let applied = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut applying,
    )
    .await;

    for peeking in [&only_peeking, &applying] {
        assert_eq!(peeking.seen.len(), 3);
        for (_, compared) in &peeking.seen {
            assert_eq!(
                compared,
                &Compared::Texts {
                    old: None,
                    new: text("copied once"),
                }
            );
        }
    }
    assert_eq!(reads(&peeked), 0);
    assert_eq!(reads(&applied), 1);
    assert_eq!(site.get(Side::B, "f.txt").unwrap(), b"copied once");
}

#[tokio::test]
async fn a_media_or_over_cap_comparison_is_answered_without_a_read() {
    let site = Site::new();
    let mut peeking = Peeking {
        compare: |_| {
            let absent = |name: &str, size| Comparison {
                path: path(name),
                old: Sided {
                    side: Side::A,
                    size: Some(size),
                },
                new: Sided {
                    side: Side::B,
                    size: Some(3),
                },
            };
            let over = Tuning::DEFAULT.peek.max_bytes + 1;
            vec![
                absent("absent.png", 3),
                absent("over.txt", over),
                absent("absent.txt", 3),
            ]
        },
        ..Peeking::new(|| {})
    };

    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut peeking,
    )
    .await;

    assert_eq!(finished.exit_code(), 0);
    // None of the three files exists: only a read would find that out.
    assert_eq!(peeking.saw("absent.png"), &Compared::Media);
    assert_eq!(
        peeking.saw("over.txt"),
        &Compared::TooLarge {
            side: Side::A,
            size: Tuning::DEFAULT.peek.max_bytes + 1,
        }
    );
    assert!(
        matches!(
            peeking.saw("absent.txt"),
            Compared::Unreadable { side: Side::A, .. }
        ),
        "{:?}",
        peeking.saw("absent.txt")
    );
}

#[tokio::test]
async fn a_binary_file_is_refused_naming_its_side() {
    let site = Site::new();
    site.put(Side::A, "blob.txt", "text at first");
    sync(&site).await;
    site.put(Side::B, "blob.txt", b"now\0binary");
    let mut peeking = Peeking::new(|| {});

    run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut peeking,
    )
    .await;

    assert_eq!(peeking.saw("blob.txt"), &Compared::Binary { side: Side::B });
}
