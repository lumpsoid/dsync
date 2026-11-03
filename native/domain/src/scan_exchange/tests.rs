//! The bucket math, and every case of
//! `test/dsync_core/scan/scan_exchange_test.dart` run through the pure
//! pieces in the order the core's exchange runs them. Each case also
//! checks the plan equals reconciling both whole listings: the exchange is
//! a wire optimization, so a difference is a bug.

use super::*;
use crate::content_hash::ContentHash;
use crate::reconcile::reconcile;
use crate::scan_entry::{FileMeta, FileState, Unchanged};
use crate::scan_result::ScanResult;
use crate::skipped_path::{SkippedPath, SkippedReason, unreadable_of};
use crate::{Action, Plan, RootKind, Side};

fn path(text: &str) -> RelPath {
    RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
}

fn file(tag: &str) -> FileState {
    let mut digest = [0u8; 32];
    digest[..tag.len()].copy_from_slice(tag.as_bytes());
    FileState {
        meta: FileMeta {
            size: 1,
            mtime_us: 2,
            mode: 0o644,
        },
        hash: ContentHash::from_digest(digest),
    }
}

fn unchanged(p: &str, tag: &str) -> ScanEntry {
    ScanEntry::new(
        path(p),
        Status::Unchanged {
            file: file(tag),
            by: Unchanged::MetadataMatched,
        },
    )
}

fn rehashed(p: &str, tag: &str) -> ScanEntry {
    ScanEntry::new(
        path(p),
        Status::Unchanged {
            file: file(tag),
            by: Unchanged::HashMatched,
        },
    )
}

fn created(p: &str, tag: &str) -> ScanEntry {
    ScanEntry::new(path(p), Status::Created(file(tag)))
}

fn modified(p: &str, tag: &str) -> ScanEntry {
    ScanEntry::new(path(p), Status::Modified(file(tag)))
}

fn deleted(p: &str) -> ScanEntry {
    ScanEntry::new(path(p), Status::Deleted)
}

fn scan(entries: Vec<ScanEntry>) -> ScanResult {
    ScanResult {
        entries,
        skipped: vec![],
    }
}

struct Exchanged {
    changed_a: ChangedScan,
    changed_b: ChangedScan,
    on_a: Vec<ScanEntry>,
    on_b: Vec<ScanEntry>,
    count: BucketCount,
    dirty: Vec<Bucket>,
}

use crate::changed_scan::ChangedScan;

/// The three phases in the order the core runs them.
fn exchange(a: ScanResult, b: ScanResult) -> Exchanged {
    let (changed_a, unchanged_a) = a.split();
    let (changed_b, unchanged_b) = b.split();
    let count = BucketCount::for_entries(changed_a.tally.total().max(changed_b.tally.total()));
    let digested_a = unchanged_a.digest(count, &changed_b.paths());
    let digested_b = unchanged_b.digest(count, &changed_a.paths());
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
fn plan_matching_full_exchange(a: ScanResult, b: ScanResult) -> Plan {
    let unreadable = unreadable_of(a.skipped.iter().chain(&b.skipped));
    let whole = reconcile(
        a.entries.clone(),
        b.entries.clone(),
        &unreadable,
        RootKind::Folder,
    );
    let phased = plan_of(&exchange(a, b));
    assert_eq!(phased, whole);
    phased
}

fn actions(plan: &Plan) -> Vec<(&str, &Action)> {
    plan.actions
        .iter()
        .map(|a| (a.action.path().as_str(), &a.action))
        .collect()
}

// -- bucket math --

#[test]
fn bucket_count_scales_with_entries_and_is_never_zero() {
    assert_eq!(BucketCount::for_entries(0).get(), 1);
    assert_eq!(BucketCount::for_entries(1).get(), 1);
    assert_eq!(BucketCount::for_entries(256).get(), 1);
    assert_eq!(BucketCount::for_entries(257).get(), 2);
    assert_eq!(BucketCount::for_entries(1000).get(), 4);
    assert_eq!(BucketCount::for_entries(14_471).get(), 57);
    assert_eq!(BucketCount::new(0), None);
    assert_eq!(
        BucketCount::new(BucketCount::MAX).map(BucketCount::get),
        Some(BucketCount::MAX)
    );
    assert_eq!(BucketCount::new(BucketCount::MAX + 1), None);
    assert_eq!(BucketCount::new(u32::MAX), None);
    assert_eq!(BucketCount::for_entries(usize::MAX).get(), BucketCount::MAX);
    assert_eq!(
        BucketCount::new(3)
            .and_then(|c| c.bucket(2))
            .map(Bucket::index),
        Some(2)
    );
    assert_eq!(BucketCount::new(3).and_then(|c| c.bucket(3)), None);
}

#[test]
fn bucket_of_is_the_first_four_digest_bytes_mod_k() {
    // sha256("a") = ca978112..., 0xca978112 = 3398926610.
    let a = path("a");
    assert_eq!(BucketCount::for_entries(1).of(&a).index(), 0);
    let k = BucketCount::new(1000).unwrap();
    assert_eq!(k.of(&a).index(), 3_398_926_610 % 1000);
    // Deterministic, and spread: 1000 paths over 4 buckets use all 4.
    let k = BucketCount::for_entries(1000);
    let used: HashSet<Bucket> = (0..1000)
        .map(|i| k.of(&path(&format!("f{i}.txt"))))
        .collect();
    assert_eq!(used.len(), 4);
}

#[test]
fn identical_inputs_give_identical_digests_whatever_the_order() {
    let k = BucketCount::new(4).unwrap();
    let forward: Vec<_> = (0..50).map(|i| unchanged(&format!("f{i}"), "h")).collect();
    let mut backward = forward.clone();
    backward.reverse();
    let a = BucketDigests::of(&forward, k);
    let b = BucketDigests::of(&backward, k);
    assert_eq!(a, b);
    assert_eq!(a.as_slice().len(), 4);
    assert_eq!(a.disagreeing_with(&b), Ok(vec![]));
}

#[test]
fn one_changed_entry_changes_exactly_its_bucket() {
    let k = BucketCount::new(8).unwrap();
    let base: Vec<_> = (0..200).map(|i| unchanged(&format!("f{i}"), "h")).collect();
    let mut changed = base.clone();
    changed[17] = unchanged("f17", "other");
    let dirty = BucketDigests::of(&base, k)
        .disagreeing_with(&BucketDigests::of(&changed, k))
        .unwrap();
    assert_eq!(dirty, [k.of(&path("f17"))]);

    // Membership alone matters too: a missing entry dirties its bucket.
    let dirty = BucketDigests::of(&base, k)
        .disagreeing_with(&BucketDigests::of(&base[1..], k))
        .unwrap();
    assert_eq!(dirty, [k.of(&path("f0"))]);
}

#[test]
fn digests_over_different_counts_are_refused() {
    let one = BucketDigests::of(&[], BucketCount::new(1).unwrap());
    let two = BucketDigests::of(&[], BucketCount::new(2).unwrap());
    assert!(one.disagreeing_with(&two).is_err());
    assert_eq!(BucketDigests::from_digests(one.as_slice().to_vec()), one);
}

#[test]
fn the_exchange_requests_only_the_differing_buckets() {
    let k = BucketCount::new(8).unwrap();
    let a: Vec<_> = (0..200).map(|i| unchanged(&format!("f{i}"), "h")).collect();
    let mut b = a.clone();
    b[17] = unchanged("f17", "other");
    let dirty_bucket = k.of(&path("f17"));

    let side_a = UnchangedEntries::new(a).digest(k, &[]);
    let side_b = UnchangedEntries::new(b).digest(k, &[]);
    let dirty = side_a.digests().disagreeing_with(side_b.digests()).unwrap();
    assert_eq!(dirty, [dirty_bucket]);

    let fetched = side_a.entries_in(&dirty);
    assert!(!fetched.is_empty());
    assert!(fetched.iter().all(|e| k.of(&e.path) == dirty_bucket));
    assert!(fetched.iter().any(|e| e.path == path("f17")));
    // Positive control for "only": the other buckets hold entries too.
    let others: Vec<Bucket> = (0..8)
        .filter_map(|i| k.bucket(i))
        .filter(|b| *b != dirty_bucket)
        .collect();
    assert!(!side_a.entries_in(&others).is_empty());
    assert!(side_a.entries_in(&[]).is_empty());
}

#[test]
fn owed_entries_are_subtracted_and_never_fetched_again() {
    let k = BucketCount::new(1).unwrap();
    let digested = UnchangedEntries::new(vec![unchanged("x", "h"), unchanged("y", "h")])
        .digest(k, &[path("x")]);
    assert_eq!(digested.owed(), [unchanged("x", "h")]);
    let all = k.bucket(0).unwrap();
    assert_eq!(digested.entries_in(&[all]), [unchanged("y", "h")]);
    assert_eq!(digested.count(), k);
}

// -- the cases that must be shown unbroken --

#[test]
fn a_fresh_replica_against_an_established_one() {
    let plan = plan_matching_full_exchange(
        scan(vec![]),
        scan(vec![
            unchanged("notes/a.txt", "aa"),
            unchanged("notes/b.txt", "bb"),
            unchanged("c.txt", "cc"),
        ]),
    );
    assert_eq!(plan.actions.len(), 3);
    assert!(
        plan.actions
            .iter()
            .all(|a| matches!(a.action, Action::Copy { from: Side::B, .. }))
    );
}

#[test]
fn a_path_present_on_one_side_and_unknown_to_the_other() {
    let plan = plan_matching_full_exchange(
        scan(vec![
            unchanged("shared.txt", "aa"),
            unchanged("mine.txt", "bb"),
        ]),
        scan(vec![unchanged("shared.txt", "aa")]),
    );
    let actions = actions(&plan);
    assert_eq!(actions.len(), 1);
    assert!(matches!(
        actions[0],
        ("mine.txt", Action::Copy { from: Side::A, .. })
    ));
}

#[test]
fn a_deletion_that_has_already_finished_on_both_sides() {
    let plan = plan_matching_full_exchange(
        scan(vec![unchanged("kept.txt", "aa"), deleted("gone.txt")]),
        scan(vec![unchanged("kept.txt", "aa")]),
    );
    assert_eq!(
        plan.actions
            .iter()
            .map(|p| p.action.clone())
            .collect::<Vec<_>>(),
        [Action::CommitOnly {
            path: path("gone.txt")
        }]
    );
}

#[test]
fn an_unreadable_path_on_one_side() {
    let a = ScanResult {
        entries: vec![unchanged("shared.txt", "aa")],
        skipped: vec![SkippedPath::new(
            path("locked.txt"),
            SkippedReason::Unreadable,
            "permission denied",
        )],
    };
    let b = scan(vec![
        unchanged("shared.txt", "aa"),
        unchanged("locked.txt", "bb"),
    ]);

    let scans = exchange(a.clone(), b.clone());
    assert_eq!(scans.changed_a.skipped.len(), 1);
    assert_eq!(scans.changed_a.skipped[0].path(), Some(&path("locked.txt")));
    assert_eq!(scans.changed_a.unreadable_count(), 1);
    assert!(scans.changed_a.unreadable().covers(&path("locked.txt")));
    // Control: the exchange did carry locked.txt to the reconciler...
    assert!(scans.on_b.iter().any(|e| e.path == path("locked.txt")));
    // ...and only the unreadable exclusion keeps it out of the plan.
    assert_eq!(plan_of(&scans), Plan::default());
    plan_matching_full_exchange(a, b);
}

#[test]
fn two_sides_that_changed_a_file_to_identical_content() {
    let plan = plan_matching_full_exchange(
        scan(vec![
            unchanged("shared.txt", "aa"),
            modified("both.txt", "ff"),
        ]),
        scan(vec![
            unchanged("shared.txt", "aa"),
            modified("both.txt", "ff"),
        ]),
    );
    assert_eq!(
        plan.actions
            .iter()
            .map(|p| p.action.clone())
            .collect::<Vec<_>>(),
        [Action::CommitOnly {
            path: path("both.txt")
        }]
    );
}

// -- the subtraction phase 2 does --

#[test]
fn a_path_created_on_one_side_and_unchanged_on_the_other_does_not_dirty_a_bucket() {
    let a = scan(vec![
        unchanged("shared.txt", "aa"),
        created("new.txt", "ff"),
    ]);
    let b = scan(vec![
        unchanged("shared.txt", "aa"),
        unchanged("new.txt", "ee"),
    ]);
    let scans = exchange(a.clone(), b.clone());
    assert!(scans.dirty.is_empty());
    let plan = plan_of(&scans);
    let actions = actions(&plan);
    assert_eq!(actions.len(), 1);
    assert!(matches!(
        actions[0],
        ("new.txt", Action::Copy { from: Side::A, .. })
    ));
    plan_matching_full_exchange(a, b);
}

/// Load-bearing, not a saving: read as silence, `unchanged x deleted`
/// becomes a commit-only and the file is never removed.
#[test]
fn a_path_unchanged_on_one_side_and_deleted_on_the_other_still_deletes() {
    let plan = plan_matching_full_exchange(
        scan(vec![unchanged("gone.txt", "aa")]),
        scan(vec![deleted("gone.txt")]),
    );
    assert_eq!(
        plan.actions
            .iter()
            .map(|p| p.action.clone())
            .collect::<Vec<_>>(),
        [Action::Delete {
            path: path("gone.txt"),
            on: Side::A
        }]
    );
}

// -- divergence detection --

#[test]
fn two_sides_both_unchanged_with_different_hashes_are_found() {
    let scans = exchange(
        scan(vec![unchanged("diverged.txt", "aa")]),
        scan(vec![unchanged("diverged.txt", "bb")]),
    );
    assert!(!scans.dirty.is_empty());
    let plan = plan_of(&scans);
    assert!(plan.actions.is_empty());
    assert_eq!(plan.conflicts.len(), 1);
    let conflict = &plan.conflicts[0];
    assert_eq!(conflict.path, path("diverged.txt"));
    assert_eq!(
        conflict.a.and_then(|s| s.file().map(|f| f.hash)),
        Some(file("aa").hash)
    );
    assert_eq!(
        conflict.b.and_then(|s| s.file().map(|f| f.hash)),
        Some(file("bb").hash)
    );
}

#[test]
fn agreeing_on_the_hash_is_still_nothing_and_still_costs_nothing() {
    let scans = exchange(
        scan(vec![
            unchanged("a.txt", "aa"),
            unchanged("b.txt", "bb"),
            unchanged("c.txt", "cc"),
        ]),
        scan(vec![
            unchanged("c.txt", "cc"),
            unchanged("a.txt", "aa"),
            unchanged("b.txt", "bb"),
        ]),
    );
    assert!(scans.dirty.is_empty());
    assert!(scans.on_a.is_empty());
    assert!(scans.on_b.is_empty());
    assert!(plan_of(&scans).actions.is_empty());
}

// -- what the exchange carries --

#[test]
fn the_tally_covers_every_path_including_the_ones_never_sent() {
    let scans = exchange(
        scan(vec![
            unchanged("a.txt", "aa"),
            rehashed("b.txt", "bb"),
            modified("c.txt", "cc"),
        ]),
        scan(vec![unchanged("a.txt", "aa")]),
    );
    let sent: Vec<_> = scans
        .changed_a
        .entries
        .iter()
        .map(|e| e.path.as_str())
        .collect();
    assert_eq!(sent, ["c.txt"]);
    let tally = scans.changed_a.tally;
    assert_eq!(tally.metadata_matched, 1);
    assert_eq!(tally.hash_matched, 1);
    assert_eq!(tally.modified, 1);
    assert_eq!(tally.total(), 3);
}

#[test]
fn a_bucket_count_scaled_to_the_larger_side() {
    let scans = exchange(
        scan(
            (0..1000)
                .map(|i| unchanged(&format!("f{i}.txt"), &format!("h{i}")))
                .collect(),
        ),
        scan(vec![unchanged("f0.txt", "h0")]),
    );
    assert_eq!(scans.count.get(), 4);
}
