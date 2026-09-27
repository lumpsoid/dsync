//! Every case of `test/dsync_core/reconcile/reconciler_test.dart`.

use super::*;
use crate::content_hash::ContentHash;
use crate::scan_entry::FileMeta;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Act {
    CopyAtoB,
    CopyBtoA,
    DeleteOnA,
    DeleteOnB,
    CommitOnly,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Unchanged,
    Created,
    Modified,
    Deleted,
}

const CHANGED: [Kind; 2] = [Kind::Created, Kind::Modified];
const PRESENT: [Kind; 3] = [Kind::Unchanged, Kind::Created, Kind::Modified];

fn path(text: &str) -> RelPath {
    RelPath::parse(text).unwrap_or_else(|e| panic!("{e}"))
}

fn hash(tag: &str) -> ContentHash {
    let mut digest = [0u8; 32];
    digest[..tag.len()].copy_from_slice(tag.as_bytes());
    ContentHash::from_digest(digest)
}

fn file(tag: &str, size: u64) -> FileState {
    FileState {
        meta: FileMeta {
            size,
            mtime_us: 1,
            mode: 0o644,
        },
        hash: hash(tag),
    }
}

fn sized(p: &str, kind: Kind, tag: &str, size: u64) -> ScanEntry {
    let file = file(tag, size);
    let status = match kind {
        Kind::Unchanged => Status::Unchanged {
            file,
            by: Unchanged::MetadataMatched,
        },
        Kind::Created => Status::Created(file),
        Kind::Modified => Status::Modified(file),
        Kind::Deleted => Status::Deleted,
    };
    ScanEntry::new(path(p), status)
}

fn hashed(p: &str, kind: Kind, tag: &str) -> ScanEntry {
    sized(p, kind, tag, 1)
}

fn entry(p: &str, kind: Kind) -> ScanEntry {
    hashed(p, kind, "h")
}

fn untrusted(p: &str, tag: &str) -> ScanEntry {
    ScanEntry::new(path(p), Status::Untrusted(file(tag, 3)))
}

fn untrusted_absent(p: &str) -> ScanEntry {
    ScanEntry::new(path(p), Status::UntrustedAbsent)
}

fn run(a: Vec<ScanEntry>, b: Vec<ScanEntry>) -> Plan {
    reconcile(a, b, &UnreadablePaths::default(), RootKind::Folder)
}

fn unreadable(roots: &[&str]) -> UnreadablePaths {
    UnreadablePaths::new(roots.iter().map(|r| path(r)))
}

fn act(action: &Action) -> Act {
    match action {
        Action::Copy { from: Side::A, .. } => Act::CopyAtoB,
        Action::Copy { from: Side::B, .. } => Act::CopyBtoA,
        Action::Delete { on: Side::A, .. } => Act::DeleteOnA,
        Action::Delete { on: Side::B, .. } => Act::DeleteOnB,
        Action::CommitOnly { .. } => Act::CommitOnly,
        Action::CopyAside { .. } => panic!("the reconciler never proposes a copy aside"),
    }
}

fn action_for(plan: &Plan, p: &str) -> Option<Act> {
    plan.actions
        .iter()
        .find(|a| a.action.path().as_str() == p)
        .map(|a| act(&a.action))
}

fn actions(plan: &Plan) -> Vec<Action> {
    plan.actions.iter().map(|p| p.action.clone()).collect()
}

fn is_conflict(plan: &Plan, p: &str) -> bool {
    plan.conflicts.iter().any(|c| c.path.as_str() == p)
}

// -- unchanged row --

#[test]
fn unchanged_unchanged_with_the_same_hash_does_nothing() {
    let plan = run(
        vec![entry("f", Kind::Unchanged)],
        vec![entry("f", Kind::Unchanged)],
    );
    assert_eq!(plan, Plan::default());
}

#[test]
fn unchanged_unchanged_with_different_hashes_conflicts() {
    let plan = run(
        vec![hashed("f", Kind::Unchanged, "a")],
        vec![hashed("f", Kind::Unchanged, "b")],
    );
    assert!(plan.actions.is_empty());
    assert!(is_conflict(&plan, "f"));
}

#[test]
fn unchanged_created_copies_b_to_a() {
    let plan = run(
        vec![hashed("f", Kind::Unchanged, "a")],
        vec![hashed("f", Kind::Created, "b")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyBtoA));
}

#[test]
fn unchanged_modified_copies_b_to_a() {
    let plan = run(
        vec![hashed("f", Kind::Unchanged, "a")],
        vec![hashed("f", Kind::Modified, "b")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyBtoA));
}

#[test]
fn unchanged_created_with_same_hash_is_commit_only() {
    let plan = run(
        vec![hashed("f", Kind::Unchanged, "same")],
        vec![hashed("f", Kind::Created, "same")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly));
}

#[test]
fn unchanged_modified_with_same_hash_is_commit_only() {
    let plan = run(
        vec![hashed("f", Kind::Unchanged, "same")],
        vec![hashed("f", Kind::Modified, "same")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly));
}

/// The deletion-propagation guard: A still holds the file (unchanged, not
/// silent), so this is not the one-sided tombstone and must still delete.
#[test]
fn unchanged_deleted_deletes_on_a() {
    let plan = run(
        vec![entry("f", Kind::Unchanged)],
        vec![entry("f", Kind::Deleted)],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::DeleteOnA));
    assert!(plan.conflicts.is_empty());
}

// -- created / modified rows --

#[test]
fn created_unchanged_copies_a_to_b() {
    let plan = run(
        vec![hashed("f", Kind::Created, "a")],
        vec![hashed("f", Kind::Unchanged, "b")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyAtoB));
}

#[test]
fn modified_unchanged_copies_a_to_b() {
    let plan = run(
        vec![hashed("f", Kind::Modified, "a")],
        vec![hashed("f", Kind::Unchanged, "b")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyAtoB));
}

#[test]
fn created_unchanged_with_same_hash_is_commit_only() {
    let plan = run(
        vec![hashed("f", Kind::Created, "same")],
        vec![hashed("f", Kind::Unchanged, "same")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly));
}

#[test]
fn modified_unchanged_with_same_hash_is_commit_only() {
    let plan = run(
        vec![hashed("f", Kind::Modified, "same")],
        vec![hashed("f", Kind::Unchanged, "same")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly));
}

/// The Dart file's loop over the four changed x changed cells, two tests
/// each (same hash, different hash).
#[test]
fn changed_changed_with_same_hash_is_commit_only() {
    for a in CHANGED {
        for b in CHANGED {
            let plan = run(vec![hashed("f", a, "same")], vec![hashed("f", b, "same")]);
            assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly), "{a:?}/{b:?}");
        }
    }
}

#[test]
fn changed_changed_with_different_hash_conflicts() {
    for a in CHANGED {
        for b in CHANGED {
            let plan = run(vec![hashed("f", a, "a")], vec![hashed("f", b, "b")]);
            assert!(is_conflict(&plan, "f"), "{a:?}/{b:?}");
            assert!(plan.actions.is_empty(), "{a:?}/{b:?}");
        }
    }
}

#[test]
fn created_deleted_conflicts() {
    let plan = run(
        vec![entry("f", Kind::Created)],
        vec![entry("f", Kind::Deleted)],
    );
    assert!(is_conflict(&plan, "f"));
}

#[test]
fn modified_deleted_conflicts() {
    let plan = run(
        vec![entry("f", Kind::Modified)],
        vec![entry("f", Kind::Deleted)],
    );
    assert!(is_conflict(&plan, "f"));
}

// -- deleted row --

#[test]
fn deleted_unchanged_deletes_on_b() {
    let plan = run(
        vec![entry("f", Kind::Deleted)],
        vec![entry("f", Kind::Unchanged)],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::DeleteOnB));
    assert!(plan.conflicts.is_empty());
}

#[test]
fn deleted_created_conflicts() {
    let plan = run(
        vec![entry("f", Kind::Deleted)],
        vec![entry("f", Kind::Created)],
    );
    assert!(is_conflict(&plan, "f"));
}

#[test]
fn deleted_modified_conflicts() {
    let plan = run(
        vec![entry("f", Kind::Deleted)],
        vec![entry("f", Kind::Modified)],
    );
    assert!(is_conflict(&plan, "f"));
}

#[test]
fn deleted_deleted_is_commit_only() {
    let plan = run(
        vec![entry("f", Kind::Deleted)],
        vec![entry("f", Kind::Deleted)],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly));
}

// -- path missing from one side entirely --

#[test]
fn present_only_on_a_freshly_created_copies_to_b() {
    let plan = run(vec![entry("f", Kind::Created)], vec![]);
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyAtoB));
}

#[test]
fn present_only_on_b_freshly_created_copies_to_a() {
    let plan = run(vec![], vec![entry("f", Kind::Created)]);
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyBtoA));
}

/// B's silence is what makes this safe: a B still holding the file would
/// report `created`. So the path is gone everywhere.
#[test]
fn deleted_on_a_never_known_on_b_tombstones_a() {
    let plan = run(vec![entry("f", Kind::Deleted)], vec![]);
    assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly));
    assert!(plan.conflicts.is_empty());
}

#[test]
fn deleted_on_b_never_known_on_a_tombstones_b() {
    let plan = run(vec![], vec![entry("f", Kind::Deleted)]);
    assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly));
    assert!(plan.conflicts.is_empty());
}

#[test]
fn unchanged_on_a_never_known_on_b_still_copies_to_b() {
    let plan = run(vec![entry("f", Kind::Unchanged)], vec![]);
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyAtoB));
    assert!(plan.conflicts.is_empty());
}

#[test]
fn unchanged_on_b_never_known_on_a_still_copies_to_a() {
    let plan = run(vec![], vec![entry("f", Kind::Unchanged)]);
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyBtoA));
    assert!(plan.conflicts.is_empty());
}

#[test]
fn modified_on_b_and_never_known_on_a_is_mirrored_not_a_conflict() {
    let plan = run(vec![], vec![entry("f", Kind::Modified)]);
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyBtoA));
    assert!(plan.conflicts.is_empty());
}

#[test]
fn a_whole_fresh_replica_mirrors_rather_than_conflicting() {
    let plan = run(
        vec![],
        vec![
            entry("a.txt", Kind::Unchanged),
            entry("b.txt", Kind::Modified),
            entry("c.txt", Kind::Created),
        ],
    );
    assert!(plan.conflicts.is_empty());
    assert_eq!(plan.actions.len(), 3);
    assert!(plan.actions.iter().all(|a| act(&a.action) == Act::CopyBtoA));
}

// -- type mismatch --

#[test]
fn a_file_on_a_and_a_directory_with_content_on_b_conflicts() {
    let plan = run(
        vec![entry("shared", Kind::Created)],
        vec![entry("shared/inner.txt", Kind::Created)],
    );
    assert!(is_conflict(&plan, "shared"));
    // The path beneath the file is covered by that conflict, not planned.
    assert!(plan.actions.is_empty());
}

#[test]
fn a_directory_with_content_on_a_and_a_file_on_b_conflicts() {
    let plan = run(
        vec![entry("shared/inner.txt", Kind::Created)],
        vec![entry("shared", Kind::Created)],
    );
    assert!(is_conflict(&plan, "shared"));
    assert_eq!(plan.conflicts.len(), 1);
    assert!(plan.actions.is_empty());
}

#[test]
fn matching_directories_on_both_sides_is_not_a_conflict() {
    let plan = run(
        vec![entry("shared/inner.txt", Kind::Created)],
        vec![entry("shared/inner.txt", Kind::Created)],
    );
    assert!(plan.conflicts.is_empty());
}

/// A deleted file where a directory now stands is no mismatch, and A's
/// stale record converges: B is silent about `shared` itself.
#[test]
fn a_file_that_used_to_exist_where_a_directory_now_stands_is_not_a_mismatch() {
    let plan = run(
        vec![entry("shared", Kind::Deleted)],
        vec![entry("shared/inner.txt", Kind::Created)],
    );
    assert!(plan.conflicts.is_empty());
    assert_eq!(action_for(&plan, "shared"), Some(Act::CommitOnly));
    assert_eq!(action_for(&plan, "shared/inner.txt"), Some(Act::CopyBtoA));
}

// -- transfer size --

#[test]
fn a_copy_carries_the_source_size_either_direction() {
    let a_to_b = run(
        vec![sized("f", Kind::Modified, "a", 4096)],
        vec![sized("f", Kind::Unchanged, "b", 1)],
    );
    let b_to_a = run(
        vec![sized("f", Kind::Unchanged, "a", 1)],
        vec![sized("f", Kind::Modified, "b", 4096)],
    );
    assert_eq!(
        actions(&a_to_b)[..],
        [Action::Copy {
            path: path("f"),
            from: Side::A,
            bytes: 4096
        }]
    );
    assert_eq!(
        actions(&b_to_a)[..],
        [Action::Copy {
            path: path("f"),
            from: Side::B,
            bytes: 4096
        }]
    );
}

#[test]
fn a_path_new_to_one_side_carries_the_other_sides_size() {
    let plan = run(vec![], vec![sized("f", Kind::Created, "h", 900)]);
    assert_eq!(plan.actions.len(), 1);
    assert_eq!(plan.actions[0].action.bytes(), 900);
}

#[test]
fn deletions_and_commit_only_move_nothing() {
    let deletion = run(
        vec![sized("f", Kind::Unchanged, "h", 4096)],
        vec![entry("f", Kind::Deleted)],
    );
    let same_content = run(
        vec![sized("f", Kind::Modified, "same", 4096)],
        vec![sized("f", Kind::Modified, "same", 4096)],
    );
    assert_eq!(deletion.actions.len(), 1);
    assert_eq!(deletion.actions[0].action.bytes(), 0);
    assert_eq!(same_content.actions.len(), 1);
    assert_eq!(act(&same_content.actions[0].action), Act::CommitOnly);
    assert_eq!(same_content.actions[0].action.bytes(), 0);
}

#[test]
fn bytes_to_transfer_sums_the_plan() {
    let plan = run(
        vec![
            sized("big", Kind::Created, "h", 5000),
            sized("small", Kind::Created, "h", 7),
            entry("gone", Kind::Deleted),
        ],
        vec![sized("gone", Kind::Unchanged, "h", 99999)],
    );
    assert_eq!(plan.bytes_to_transfer(), 5007);
    assert!(plan.exceeds_warn_size(Some(5006)));
    assert!(!plan.exceeds_warn_size(Some(5007)));
    assert!(!plan.exceeds_warn_size(None));
}

// -- deterministic ordering --

#[test]
fn actions_and_conflicts_are_sorted_by_path() {
    let plan = run(
        vec![
            entry("z.txt", Kind::Created),
            entry("a.txt", Kind::Created),
            hashed("y.txt", Kind::Modified, "a"),
            hashed("b.txt", Kind::Modified, "a"),
        ],
        vec![
            hashed("y.txt", Kind::Modified, "b"),
            hashed("b.txt", Kind::Modified, "b"),
        ],
    );
    let actions: Vec<_> = plan
        .actions
        .iter()
        .map(|a| a.action.path().as_str())
        .collect();
    let conflicts: Vec<_> = plan.conflicts.iter().map(|c| c.path.as_str()).collect();
    assert_eq!(actions, ["a.txt", "z.txt"]);
    assert_eq!(conflicts, ["b.txt", "y.txt"]);
}

// -- unreadable paths (SPEC §5) --

#[test]
fn a_path_one_side_could_not_read_gets_no_action() {
    // Control: without the exclusion, A's silence mirrors B's copy.
    let b = vec![hashed("f.txt", Kind::Unchanged, "b")];
    assert_eq!(
        action_for(&run(vec![], b.clone()), "f.txt"),
        Some(Act::CopyBtoA)
    );

    let plan = reconcile(vec![], b, &unreadable(&["f.txt"]), RootKind::Folder);
    assert_eq!(plan, Plan::default());
}

#[test]
fn nor_a_conflict() {
    let a = vec![hashed("f.txt", Kind::Modified, "a")];
    let b = vec![hashed("f.txt", Kind::Modified, "b")];
    assert!(is_conflict(&run(a.clone(), b.clone()), "f.txt"));

    let plan = reconcile(a, b, &unreadable(&["f.txt"]), RootKind::Folder);
    assert_eq!(plan, Plan::default());
}

#[test]
fn an_unreadable_directory_covers_everything_beneath_it() {
    let plan = reconcile(
        vec![],
        vec![hashed("sub/inner.txt", Kind::Unchanged, "b")],
        &unreadable(&["sub"]),
        RootKind::Folder,
    );
    assert!(plan.actions.is_empty());
}

#[test]
fn a_sibling_whose_name_merely_starts_with_an_unreadable_path_is_reconciled() {
    let plan = reconcile(
        vec![],
        vec![sized("submarine.txt", Kind::Created, "b", 4)],
        &unreadable(&["sub"]),
        RootKind::Folder,
    );
    let paths: Vec<_> = plan
        .actions
        .iter()
        .map(|a| a.action.path().as_str())
        .collect();
    assert_eq!(paths, ["submarine.txt"]);
}

#[test]
fn every_other_path_still_reconciles_normally() {
    let plan = reconcile(
        vec![sized("ok.txt", Kind::Created, "a", 5)],
        vec![],
        &unreadable(&["locked.txt"]),
        RootKind::Folder,
    );
    assert_eq!(plan.actions.len(), 1);
    assert_eq!(action_for(&plan, "ok.txt"), Some(Act::CopyAtoB));
}

// -- untrusted (SPEC §7.6) --

#[test]
fn untrusted_holding_the_other_sides_content_is_committed_not_copied() {
    for other in PRESENT {
        let toward_b = run(vec![entry("f", other)], vec![untrusted("f", "h")]);
        assert_eq!(
            action_for(&toward_b, "f"),
            Some(Act::CommitOnly),
            "{other:?}"
        );
        assert!(toward_b.conflicts.is_empty(), "{other:?}");

        let toward_a = run(vec![untrusted("f", "h")], vec![entry("f", other)]);
        assert_eq!(
            action_for(&toward_a, "f"),
            Some(Act::CommitOnly),
            "{other:?}"
        );
        assert!(toward_a.conflicts.is_empty(), "{other:?}");
    }
}

#[test]
fn untrusted_holding_anything_else_is_an_interrupted_conflict() {
    for other in PRESENT {
        for plan in [
            run(vec![entry("f", other)], vec![untrusted("f", "torn")]),
            run(vec![untrusted("f", "torn")], vec![entry("f", other)]),
        ] {
            assert!(plan.actions.is_empty(), "{other:?}");
            assert_eq!(plan.conflicts.len(), 1, "{other:?}");
            assert!(plan.conflicts[0].interrupted(), "{other:?}");
        }
    }
}

#[test]
fn untrusted_is_mirrored_onto_when_absent() {
    let plan = run(
        vec![entry("f", Kind::Unchanged)],
        vec![untrusted_absent("f")],
    );
    assert_eq!(action_for(&plan, "f"), Some(Act::CopyAtoB));
    let mirrored = run(
        vec![untrusted_absent("f")],
        vec![sized("f", Kind::Created, "h", 7)],
    );
    assert_eq!(
        actions(&mirrored)[..],
        [Action::Copy {
            path: path("f"),
            from: Side::B,
            bytes: 7
        }]
    );
}

#[test]
fn untrusted_with_nothing_on_the_other_side_is_a_conflict_rather_than_deleted() {
    for (a, b) in [
        (vec![], vec![untrusted("f", "torn")]),
        (
            vec![entry("f", Kind::Deleted)],
            vec![untrusted("f", "torn")],
        ),
        (vec![untrusted("f", "torn")], vec![]),
        (
            vec![untrusted("f", "torn")],
            vec![entry("f", Kind::Deleted)],
        ),
    ] {
        let plan = run(a, b);
        assert!(plan.actions.is_empty());
        assert_eq!(plan.conflicts.len(), 1);
        assert!(plan.conflicts[0].interrupted());
    }
}

#[test]
fn an_ordinary_conflict_is_not_labelled_interrupted() {
    let plan = run(
        vec![hashed("f", Kind::Modified, "x")],
        vec![hashed("f", Kind::Modified, "y")],
    );
    assert_eq!(plan.conflicts.len(), 1);
    assert!(!plan.conflicts[0].interrupted());
}

#[test]
fn untrusted_with_nothing_to_mirror_and_no_file_only_clears_the_mark() {
    for (a, b) in [
        (vec![], vec![untrusted_absent("f")]),
        (vec![entry("f", Kind::Deleted)], vec![untrusted_absent("f")]),
        (vec![untrusted_absent("f")], vec![]),
        (vec![untrusted_absent("f")], vec![entry("f", Kind::Deleted)]),
    ] {
        let plan = run(a, b);
        assert_eq!(action_for(&plan, "f"), Some(Act::CommitOnly));
        assert!(plan.conflicts.is_empty());
    }
}

#[test]
fn untrusted_on_both_sides_is_a_conflict() {
    for (a, b) in [
        (untrusted("f", "h"), untrusted("f", "h")),
        (untrusted("f", "h"), untrusted_absent("f")),
        (untrusted_absent("f"), untrusted_absent("f")),
    ] {
        let plan = run(vec![a], vec![b]);
        assert!(plan.actions.is_empty());
        assert!(is_conflict(&plan, "f"));
    }
}

#[test]
fn an_absent_untrusted_one_is_no_file_for_a_type_mismatch() {
    let plan = run(
        vec![untrusted_absent("d"), entry("d/x", Kind::Created)],
        vec![entry("d/x", Kind::Created)],
    );
    assert!(plan.conflicts.is_empty());
    // Control: a present untrusted file there is a mismatch.
    let mismatch = run(
        vec![untrusted("d", "h"), entry("d/x", Kind::Created)],
        vec![entry("d/x", Kind::Created)],
    );
    assert!(is_conflict(&mismatch, "d"));
}

// -- beyond the Dart file --

#[test]
fn a_conflict_carries_both_sides_statuses() {
    let plan = run(
        vec![hashed("f", Kind::Unchanged, "aa")],
        vec![hashed("f", Kind::Unchanged, "bb")],
    );
    let conflict = &plan.conflicts[0];
    assert_eq!(
        conflict.a.and_then(|s| s.file().map(|f| f.hash)),
        Some(hash("aa"))
    );
    assert_eq!(
        conflict.on(Side::B).and_then(|s| s.file().map(|f| f.hash)),
        Some(hash("bb"))
    );

    let one_sided = run(vec![untrusted("f", "h")], vec![]);
    assert_eq!(one_sided.conflicts[0].b, None);
}

#[test]
fn a_path_beneath_a_file_on_either_side_is_left_to_that_conflict() {
    let plan = run(
        vec![entry("d", Kind::Unchanged), entry("x", Kind::Created)],
        vec![entry("d/a/b", Kind::Created), entry("d/c", Kind::Modified)],
    );
    let conflicts: Vec<_> = plan.conflicts.iter().map(|c| c.path.as_str()).collect();
    assert_eq!(conflicts, ["d"]);
    let actions: Vec<_> = plan
        .actions
        .iter()
        .map(|a| a.action.path().as_str())
        .collect();
    assert_eq!(actions, ["x"]);
}

// -- reversals (SPEC §6: "a proposal may carry a reversal") --

fn only(plan: &Plan) -> &Proposal {
    assert_eq!(plan.actions.len(), 1, "{plan:?}");
    &plan.actions[0]
}

#[test]
fn a_copy_over_a_file_reverses_to_the_opposite_copy_with_the_other_sides_size() {
    let plan = run(
        vec![sized("f", Kind::Modified, "a", 4096)],
        vec![sized("f", Kind::Unchanged, "b", 17)],
    );
    let proposal = only(&plan);
    assert_eq!(act(&proposal.action), Act::CopyAtoB);
    assert_eq!(proposal.reverse_bytes, Some(17));
    assert_eq!(
        proposal.reversed(),
        Some(Action::Copy {
            path: path("f"),
            from: Side::B,
            bytes: 17
        })
    );
}

#[test]
fn a_mirror_onto_a_silent_or_untrusted_absent_side_offers_no_reversal() {
    let silent = run(vec![sized("f", Kind::Created, "a", 4096)], vec![]);
    assert_eq!(act(&only(&silent).action), Act::CopyAtoB);
    assert_eq!(only(&silent).reverse_bytes, None);
    assert_eq!(only(&silent).reversed(), None);

    let absent = run(
        vec![sized("f", Kind::Unchanged, "a", 4096)],
        vec![untrusted_absent("f")],
    );
    assert_eq!(act(&only(&absent).action), Act::CopyAtoB);
    assert_eq!(only(&absent).reversed(), None);

    // Control: the same copy onto a side holding a file is offered one.
    let over_a_file = run(
        vec![sized("f", Kind::Modified, "a", 4096)],
        vec![sized("f", Kind::Unchanged, "b", 3)],
    );
    assert_eq!(act(&only(&over_a_file).action), Act::CopyAtoB);
    assert_eq!(only(&over_a_file).reverse_bytes, Some(3));
}

#[test]
fn a_delete_reverses_to_restoring_the_deleted_sides_file_from_its_holder() {
    let on_b = run(
        vec![entry("f", Kind::Deleted)],
        vec![sized("f", Kind::Unchanged, "b", 9)],
    );
    assert_eq!(act(&only(&on_b).action), Act::DeleteOnB);
    assert_eq!(
        only(&on_b).reversed(),
        Some(Action::Copy {
            path: path("f"),
            from: Side::B,
            bytes: 9
        })
    );
    let on_a = run(
        vec![sized("f", Kind::Unchanged, "a", 5)],
        vec![entry("f", Kind::Deleted)],
    );
    assert_eq!(act(&only(&on_a).action), Act::DeleteOnA);
    assert_eq!(
        only(&on_a).reversed(),
        Some(Action::Copy {
            path: path("f"),
            from: Side::A,
            bytes: 5
        })
    );
}

#[test]
fn commit_only_offers_no_reversal() {
    let plan = run(
        vec![sized("f", Kind::Modified, "same", 4096)],
        vec![sized("f", Kind::Created, "same", 4096)],
    );
    assert_eq!(act(&only(&plan).action), Act::CommitOnly);
    assert_eq!(only(&plan).reverse_bytes, None);
    assert_eq!(only(&plan).reversed(), None);
}
