use dsync_domain::{
    Action, Conflict, EntryId, Jobs, MassDelete, MassDeletePolicy, Plan, Proposal, RelPath,
    RootKind, Side, Tuning,
};

use super::{ActionChoice, ConflictChoice, Recall, Recalled, RowRecall};
use crate::local_replica::LocalReplica;
use crate::run::decider::Decider;
use crate::run::peek::Peek;
use crate::state_dir::StateDir;
use crate::{Root, Symlinks};

fn path(text: &str) -> RelPath {
    RelPath::parse(text).unwrap()
}

fn copy(at: &str, bytes: u64, reverse_bytes: Option<u64>) -> Proposal {
    Proposal {
        action: Action::Copy {
            path: path(at),
            from: Side::A,
            bytes,
        },
        reverse_bytes,
    }
}

fn commit_only(at: &str) -> Proposal {
    Proposal {
        action: Action::CommitOnly { path: path(at) },
        reverse_bytes: None,
    }
}

fn conflict(at: &str, root_kind: RootKind) -> Conflict {
    Conflict {
        path: path(at),
        a: None,
        b: None,
        root_kind,
        cause: dsync_domain::ConflictCause::Changes,
    }
}

/// An inner decider answering by fixed rules, counting how it was asked.
#[derive(Default)]
struct Fake {
    vetoes: Vec<&'static str>,
    reverses: Vec<&'static str>,
    keeps: Vec<(&'static str, Side)>,
    /// Keep-both copies it answers with, each settling its conflict.
    asides: Vec<Action>,
    /// Answers with this too: an action no row offered.
    stray: Option<Action>,
    confirms: bool,
    decides: usize,
    asked_again: Vec<Recall>,
    carried: usize,
    asked_deletes: usize,
}

impl Fake {
    fn answer(&self, plan: &Plan) -> Vec<Action> {
        let kept = plan.actions.iter().filter_map(|proposal| {
            let at = proposal.action.path().as_str();
            if self.vetoes.contains(&at) {
                None
            } else if self.reverses.contains(&at) {
                proposal.reversed()
            } else {
                Some(proposal.action.clone())
            }
        });
        let resolved = plan.conflicts.iter().filter_map(|conflict| {
            self.keeps
                .iter()
                .find(|(at, _)| *at == conflict.path.as_str())
                .map(|&(_, side)| conflict.resolve(side))
        });
        kept.chain(resolved)
            .chain(self.asides.iter().cloned())
            .chain(self.stray.clone())
            .collect()
    }
}

impl Decider for Fake {
    async fn decide<A: crate::Replica, B: crate::Replica>(
        &mut self,
        plan: &Plan,
        _: Peek<'_, A, B>,
    ) -> Vec<Action> {
        self.decides += 1;
        self.answer(plan)
    }

    async fn decide_again<A: crate::Replica, B: crate::Replica>(
        &mut self,
        plan: &Plan,
        _: Peek<'_, A, B>,
        recall: &Recall,
    ) -> Vec<Action> {
        self.asked_again.push(recall.clone());
        self.answer(plan)
    }

    fn carried(&mut self, _: &Plan, _: &Recall) {
        self.carried += 1;
    }

    async fn confirm_deletes(&mut self, _: &MassDelete) -> bool {
        self.asked_deletes += 1;
        self.confirms
    }
}

fn replica(side: Side) -> LocalReplica {
    LocalReplica::open(
        Root::folder("/nowhere".to_owned()),
        StateDir::new("/nowhere/state"),
        EntryId::parse("0123456789abcdef0123456789abcdef").unwrap(),
        side,
        Jobs::DEFAULT,
        Tuning::DEFAULT,
        Symlinks::AsRuled,
    )
}

/// One attempt reaching its plan.
async fn decide(recalled: &mut Recalled<'_, Fake>, plan: &Plan) -> Vec<Action> {
    let (a, b) = (replica(Side::A), replica(Side::B));
    recalled
        .decide(plan, Peek::new(&a, &b, Tuning::DEFAULT.peek))
        .await
}

/// Approves `x`, vetoes `y`, reverses `z`; keeps A on conflict `c`, leaves
/// `d` open.
fn answered() -> Fake {
    Fake {
        vetoes: vec!["y"],
        reverses: vec!["z"],
        keeps: vec![("c", Side::A)],
        ..Fake::default()
    }
}

fn first_plan() -> Plan {
    Plan {
        actions: vec![
            copy("x", 10, None),
            copy("y", 1, None),
            copy("z", 5, Some(7)),
        ],
        conflicts: vec![
            conflict("c", RootKind::Folder),
            conflict("d", RootKind::Folder),
        ],
    }
}

#[tokio::test]
async fn the_first_attempt_asks_the_inner_decider() {
    let mut inner = answered();
    let mut recalled = Recalled::new(&mut inner);
    let answer = decide(&mut recalled, &first_plan()).await;
    drop(recalled);
    assert_eq!(inner.decides, 1);
    assert_eq!(inner.carried, 0);
    assert_eq!(answer, inner.answer(&first_plan()));
}

#[tokio::test]
async fn an_unchanged_replan_keeps_every_answer_without_asking() {
    let mut inner = answered();
    let mut recalled = Recalled::new(&mut inner);
    let first = decide(&mut recalled, &first_plan()).await;
    let second = decide(&mut recalled, &first_plan()).await;
    let third = decide(&mut recalled, &first_plan()).await;
    drop(recalled);

    assert_eq!((inner.decides, inner.asked_again.len()), (1, 0));
    assert_eq!(inner.carried, 2);
    assert_eq!(second, first);
    assert_eq!(third, first);
    // Vetoed `y` stays out, `z` stays reversed, `c` stays resolved and
    // `d` open.
    assert_eq!(
        second,
        [
            Action::Copy {
                path: path("x"),
                from: Side::A,
                bytes: 10
            },
            Action::Copy {
                path: path("z"),
                from: Side::B,
                bytes: 7
            },
            conflict("c", RootKind::Folder).resolve(Side::A),
        ]
    );
}

#[tokio::test]
async fn a_kept_both_conflict_carries_its_copy_aside_without_asking() {
    let aside = Action::CopyAside {
        path: path("c"),
        from: Side::B,
        to: path("c (b).txt"),
        bytes: 3,
    };
    let mut inner = Fake {
        asides: vec![aside.clone()],
        ..Fake::default()
    };
    let plan = Plan {
        actions: vec![copy("x", 10, None)],
        conflicts: vec![conflict("c", RootKind::Folder)],
    };
    let mut recalled = Recalled::new(&mut inner);
    let first = decide(&mut recalled, &plan).await;
    let second = decide(&mut recalled, &plan).await;
    drop(recalled);

    assert_eq!((inner.decides, inner.asked_again.len()), (1, 0));
    assert_eq!(inner.carried, 1);
    assert_eq!(second, first);
    assert_eq!(second, [plan.actions[0].action.clone(), aside]);
}

/// Conflict `c`, both sides modified, as a scan that read them at
/// `read_us` would report it.
fn conflict_read_at(read_us: i64) -> Conflict {
    let file = |byte| dsync_domain::FileState {
        meta: dsync_domain::FileMeta {
            size: 3,
            mtime_us: 1,
            mode: 0o644,
            read_us,
        },
        hash: dsync_domain::ContentHash::from_digest([byte; 32]),
    };
    Conflict {
        a: Some(dsync_domain::Status::Modified(file(1))),
        b: Some(dsync_domain::Status::Modified(file(2))),
        ..conflict("c", RootKind::Folder)
    }
}

#[tokio::test]
async fn a_conflict_rescanned_unchanged_carries_its_answer_across_a_redial() {
    // Every re-dial rescans, and every scan reads each file afresh.
    let plan = |read_us| Plan {
        actions: vec![copy("x", 10, None)],
        conflicts: vec![conflict_read_at(read_us)],
    };
    let mut inner = Fake {
        keeps: vec![("c", Side::B)],
        ..Fake::default()
    };
    let mut recalled = Recalled::new(&mut inner);
    let first = decide(&mut recalled, &plan(1)).await;
    let again = decide(&mut recalled, &plan(2)).await;
    // The positive control: a conflict that did change is asked again.
    let mut edited = plan(3);
    edited.conflicts[0].b = None;
    decide(&mut recalled, &edited).await;
    drop(recalled);

    assert_eq!(inner.decides, 1);
    assert_eq!(inner.carried, 1, "{:?}", inner.asked_again);
    assert_eq!(again, first);
    assert_eq!(
        again[1],
        conflict_read_at(2).resolve(Side::B),
        "kept B, resolved over the new scan"
    );
    assert_eq!(inner.asked_again.len(), 1);
}

#[tokio::test]
async fn one_changed_proposal_is_asked_again_with_the_rest_recalled() {
    let mut inner = answered();
    let mut recalled = Recalled::new(&mut inner);
    decide(&mut recalled, &first_plan()).await;
    let mut changed = first_plan();
    changed.actions[0] = copy("x", 11, None);
    decide(&mut recalled, &changed).await;
    // That answer is the record now: the same plan again carries.
    decide(&mut recalled, &changed).await;
    drop(recalled);

    assert_eq!(inner.decides, 1);
    assert_eq!(inner.carried, 1);
    let [recall] = inner.asked_again.as_slice() else {
        panic!("{:?}", inner.asked_again);
    };
    assert_eq!(
        recall.actions(),
        [
            RowRecall::Changed {
                was: Some(copy("x", 10, None))
            },
            RowRecall::Carried(ActionChoice::Vetoed),
            RowRecall::Carried(ActionChoice::Reversed),
        ]
    );
    assert_eq!(
        recall.conflicts(),
        [
            RowRecall::Carried(ConflictChoice::Keep(Side::A)),
            RowRecall::Carried(ConflictChoice::Unresolved),
        ]
    );
}

#[tokio::test]
async fn a_changed_conflict_or_a_new_path_is_asked_again() {
    let mut inner = answered();
    let mut recalled = Recalled::new(&mut inner);
    decide(&mut recalled, &first_plan()).await;
    let mut changed = first_plan();
    changed.actions.push(copy("w", 3, None));
    changed.conflicts[0] = conflict("c", RootKind::File);
    changed.conflicts.push(conflict("e", RootKind::Folder));
    decide(&mut recalled, &changed).await;
    drop(recalled);

    let [recall] = inner.asked_again.as_slice() else {
        panic!("{:?}", inner.asked_again);
    };
    assert_eq!(recall.actions()[3], RowRecall::Changed { was: None });
    assert_eq!(
        recall.conflicts(),
        [
            RowRecall::Changed {
                was: Some(conflict("c", RootKind::Folder))
            },
            RowRecall::Carried(ConflictChoice::Unresolved),
            RowRecall::Changed { was: None },
        ]
    );
}

#[tokio::test]
async fn commit_only_rows_and_what_remains_unchanged_carry() {
    let mut inner = answered();
    let mut recalled = Recalled::new(&mut inner);
    decide(&mut recalled, &first_plan()).await;
    // `x` landed before the drop and is only committed now; `z` and the
    // conflicts are done; `y` is still vetoed; `v` landed unasked.
    let remaining = Plan {
        actions: vec![commit_only("x"), copy("y", 1, None), commit_only("v")],
        conflicts: vec![],
    };
    let answer = decide(&mut recalled, &remaining).await;
    drop(recalled);

    assert_eq!((inner.decides, inner.asked_again.len()), (1, 0));
    assert_eq!(inner.carried, 1);
    assert_eq!(answer, [commit_only("x").action, commit_only("v").action]);
}

#[tokio::test]
async fn an_answer_no_row_offered_is_not_carried() {
    let mut inner = Fake {
        stray: Some(commit_only("elsewhere").action),
        ..answered()
    };
    let mut recalled = Recalled::new(&mut inner);
    decide(&mut recalled, &first_plan()).await;
    decide(&mut recalled, &first_plan()).await;
    drop(recalled);

    assert_eq!(inner.decides, 2);
    assert_eq!(inner.carried, 0);
}

/// `b` files deleted on side B out of 20, `a` on side A out of 20.
fn verdict(a: usize, b: usize) -> MassDelete {
    let deletes = |on, count| {
        (0..count).map(move |index| Action::Delete {
            path: path(&format!("f{index:02}")),
            on,
        })
    };
    let kept: Vec<Action> = deletes(Side::A, a).chain(deletes(Side::B, b)).collect();
    MassDeletePolicy::DEFAULT.judge(&kept, [20, 20]).unwrap()
}

#[tokio::test]
async fn a_confirmed_delete_guard_holds_until_a_side_deletes_more() {
    let mut inner = Fake {
        confirms: true,
        ..Fake::default()
    };
    let mut recalled = Recalled::new(&mut inner);
    let mut answers = Vec::new();
    for verdict in [
        verdict(0, 15),
        verdict(0, 15),
        verdict(0, 12),
        verdict(0, 16),
        verdict(0, 16),
        verdict(11, 16),
    ] {
        answers.push(recalled.confirm_deletes(&verdict).await);
    }
    drop(recalled);

    assert_eq!(answers, [true; 6]);
    // Asked first, then at 16 on B, then when A tripped too.
    assert_eq!(inner.asked_deletes, 3);
}

#[tokio::test]
async fn an_unconfirmed_delete_guard_is_asked_every_time() {
    let mut inner = Fake::default();
    let mut recalled = Recalled::new(&mut inner);
    let first = recalled.confirm_deletes(&verdict(0, 15)).await;
    let second = recalled.confirm_deletes(&verdict(0, 15)).await;
    drop(recalled);

    assert!(!first && !second);
    assert_eq!(inner.asked_deletes, 2);
}
