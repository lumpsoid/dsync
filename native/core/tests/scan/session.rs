//! The local scan session through SPEC §6.1's three phases: two real
//! replicas scanned, exchanged through the domain's bucket math, and
//! reconciled - asserted equal to reconciling both whole listings, since
//! the exchange is a wire optimization and any difference is a bug.
//! (Every case of `scan_exchange_test.dart` on plain values is in the
//! domain's `scan_exchange` tests.)

use dsync_core::ScanSession;
use dsync_domain::{
    Action, Archive, ArchiveCommit, Bucket, BucketCount, ChangedScan, Plan, RootKind, RuleSet,
    ScanEntry, ScanResult, Side, reconcile, status_list, unreadable_of,
};

use crate::support::*;

struct Exchanged {
    changed_a: ChangedScan,
    changed_b: ChangedScan,
    on_a: Vec<ScanEntry>,
    on_b: Vec<ScanEntry>,
    count: BucketCount,
    dirty: Vec<Bucket>,
}

/// The three phases in the order a run drives them.
fn exchange(a: ScanSession, b: ScanSession) -> Exchanged {
    let changed_a = a.changed().clone();
    let changed_b = b.changed().clone();
    let count = BucketCount::for_entries(changed_a.tally.total().max(changed_b.tally.total()));
    let digested_a = a.digests(count, &changed_b.paths());
    let digested_b = b.digests(count, &changed_a.paths());
    let dirty = digested_a
        .digests()
        .disagreeing_with(digested_b.digests())
        .unwrap();
    let on_a = status_list(
        changed_a.entries.clone(),
        digested_a.owed().to_vec(),
        digested_a.entries_in(&dirty),
    );
    let on_b = status_list(
        changed_b.entries.clone(),
        digested_b.owed().to_vec(),
        digested_b.entries_in(&dirty),
    );
    Exchanged {
        changed_a,
        changed_b,
        on_a,
        on_b,
        count,
        dirty,
    }
}

fn plan_of(scans: &Exchanged) -> Plan {
    let unreadable = unreadable_of(
        scans
            .changed_a
            .skipped
            .iter()
            .chain(&scans.changed_b.skipped),
    );
    reconcile(
        scans.on_a.clone(),
        scans.on_b.clone(),
        &unreadable,
        RootKind::Folder,
    )
}

/// The exchange's plan, asserted equal to the whole-listing plan.
fn plan_matching_whole_listings(a: ScanResult, b: ScanResult) -> (Plan, Exchanged) {
    let unreadable = unreadable_of(a.skipped.iter().chain(&b.skipped));
    let whole = reconcile(
        a.entries.clone(),
        b.entries.clone(),
        &unreadable,
        RootKind::Folder,
    );
    let scans = exchange(ScanSession::new(a), ScanSession::new(b));
    let phased = plan_of(&scans);
    assert_eq!(phased, whole);
    (phased, scans)
}

/// What a completed sync would have committed for `tree`: every file as
/// it scans now.
fn committed(tree: &Tree) -> Archive {
    let result = tree.scan_fresh();
    Archive::replay(result.entries.iter().map(|entry| ArchiveCommit::Upsert {
        path: entry.path.clone(),
        file: *entry.status.file().unwrap(),
    }))
}

fn actions(plan: &Plan) -> Vec<(&str, &Action)> {
    plan.actions
        .iter()
        .map(|a| (a.action.path().as_str(), &a.action))
        .collect()
}

#[test]
fn two_real_replicas_exchange_only_what_changed_and_plan_as_whole_listings_would() {
    let a = Tree::new();
    let b = Tree::new();
    for i in 0..300 {
        let (name, body) = (format!("shared/f{i:03}.txt"), format!("content {i}"));
        a.write(&name, &body);
        b.write(&name, &body);
    }
    a.write("gone-on-a.txt", "x");
    b.write("gone-on-a.txt", "x");
    let archive_a = committed(&a);
    let archive_b = committed(&b);

    a.write("new-on-a.txt", "fresh");
    b.write("shared/f007.txt", "edited on b");
    std::fs::remove_file(a.at("gone-on-a.txt")).unwrap();

    let scan_a = a.scan(&archive_a, &RuleSet::default());
    let scan_b = b.scan(&archive_b, &RuleSet::default());
    let (plan, scans) = plan_matching_whole_listings(scan_a, scan_b);

    assert_eq!(
        actions(&plan),
        [
            (
                "gone-on-a.txt",
                &Action::Delete {
                    path: path("gone-on-a.txt"),
                    on: Side::B
                }
            ),
            (
                "new-on-a.txt",
                &Action::Copy {
                    path: path("new-on-a.txt"),
                    from: Side::A,
                    bytes: 5
                }
            ),
            (
                "shared/f007.txt",
                &Action::Copy {
                    path: path("shared/f007.txt"),
                    from: Side::B,
                    bytes: 11
                }
            ),
        ]
    );
    // Phase 1 carried only the changes; the 300 agreeing paths were proven
    // equal by digest, and no bucket was dirty.
    let changed_a: Vec<&str> = scans
        .changed_a
        .entries
        .iter()
        .map(|e| e.path.as_str())
        .collect();
    assert_eq!(changed_a, ["new-on-a.txt", "gone-on-a.txt"]);
    assert_eq!(scans.changed_b.entries.len(), 1);
    assert_eq!(scans.changed_a.tally.total(), 302);
    assert_eq!(scans.count.get(), 2);
    assert!(scans.dirty.is_empty());
    // B owed its unchanged entry for the path A deleted, and A's for B's
    // edit: without them `unchanged x deleted` would never delete.
    assert!(
        scans
            .on_b
            .iter()
            .any(|e| e.path.as_str() == "gone-on-a.txt")
    );
    assert!(
        scans
            .on_a
            .iter()
            .any(|e| e.path.as_str() == "shared/f007.txt")
    );
}

#[test]
fn a_fresh_replica_against_an_established_one_fetches_the_dirty_buckets() {
    let a = Tree::new();
    let b = Tree::new();
    for name in ["notes/a.txt", "notes/b.txt", "c.txt"] {
        b.write(name, name);
    }
    let archive_b = committed(&b);

    let scan_a = a.scan_fresh();
    let scan_b = b.scan(&archive_b, &RuleSet::default());
    let (plan, scans) = plan_matching_whole_listings(scan_a, scan_b);

    // Every path of B was unchanged, so none was sent in phase 1; they
    // reach A through the buckets the digests found dirty.
    assert!(scans.changed_b.entries.is_empty());
    assert!(!scans.dirty.is_empty());
    assert_eq!(plan.actions.len(), 3);
    assert!(
        plan.actions
            .iter()
            .all(|a| matches!(a.action, Action::Copy { from: Side::B, .. }))
    );
}

#[test]
fn two_replicas_that_diverged_silently_are_found() {
    let a = Tree::new();
    let b = Tree::new();
    a.write("diverged.txt", "aa");
    b.write("diverged.txt", "bb");
    // Each archive agrees with its own replica, so both scan unchanged.
    let (archive_a, archive_b) = (committed(&a), committed(&b));

    let scans = exchange(
        ScanSession::new(a.scan(&archive_a, &RuleSet::default())),
        ScanSession::new(b.scan(&archive_b, &RuleSet::default())),
    );

    assert!(scans.changed_a.entries.is_empty() && scans.changed_b.entries.is_empty());
    assert!(!scans.dirty.is_empty());
    let plan = plan_of(&scans);
    assert!(plan.actions.is_empty());
    assert_eq!(plan.conflicts.len(), 1);
}

#[cfg(unix)]
#[test]
fn skipped_paths_travel_in_phase_one() {
    let a = Tree::new();
    let b = Tree::new();
    a.write("shared.txt", "same");
    b.write("shared.txt", "same");
    a.write("a\\b.txt", "unrepresentable");

    let scans = exchange(
        ScanSession::new(a.scan_fresh()),
        ScanSession::new(b.scan_fresh()),
    );

    assert_eq!(scans.changed_a.unreadable_count(), 1);
    assert_eq!(plan_of(&scans).actions.len(), 1, "shared.txt commits");
}
