use dsync_core::{BatchDecider, Decider, DryRunDecider};
use dsync_domain::{Action, Plan, Side, Status};
use tokio::sync::watch;

use super::InteractiveDecider;
use crate::render::fixtures::{conflict, created, path};
use crate::test_support::with_deadline;

fn copy(at: &str, from: Side, bytes: u64) -> Action {
    Action::Copy {
        path: path(at),
        from,
        bytes,
    }
}

/// What the decider kept, and what it printed, answering `script`.
async fn review(plan: &Plan, script: &str) -> (Vec<Action>, String) {
    let (_shown, plan_shown) = watch::channel(true);
    let mut output = Vec::new();
    let mut decider = InteractiveDecider::new(script.as_bytes(), &mut output, plan_shown);
    let kept = with_deadline("the review", decider.decide(plan)).await;
    drop(decider);
    (kept, String::from_utf8(output).unwrap())
}

fn actions(actions: Vec<Action>) -> Plan {
    Plan {
        actions,
        conflicts: vec![],
    }
}

#[tokio::test]
async fn accepts_one_action_and_skips_another() {
    let plan = actions(vec![copy("a", Side::A, 1), copy("b", Side::A, 1)]);
    let (kept, _) = review(&plan, "y\ns\n").await;
    assert_eq!(kept, [copy("a", Side::A, 1)]);
}

#[tokio::test]
async fn a_deletion_is_prompted_and_can_be_vetoed() {
    let delete = Action::Delete {
        path: path("gone"),
        on: Side::B,
    };
    let (kept, printed) = review(&actions(vec![delete]), "s\n").await;
    assert!(kept.is_empty());
    assert!(printed.contains("--- delete on B: gone"), "{printed}");
}

#[tokio::test]
async fn accept_all_takes_the_rest_without_asking() {
    let plan = actions(vec![
        copy("a", Side::A, 1),
        copy("b", Side::A, 1),
        copy("c", Side::A, 1),
    ]);
    let (kept, printed) = review(&plan, "s\na\n").await;
    assert_eq!(kept, [copy("b", Side::A, 1), copy("c", Side::A, 1)]);
    assert!(!printed.contains(": c"), "c was asked about:\n{printed}");
}

#[tokio::test]
async fn quit_stops_asking_and_leaves_the_rest_out() {
    let plan = actions(vec![copy("a", Side::A, 1), copy("b", Side::A, 1)]);
    let (kept, printed) = review(&plan, "y\nq\n").await;
    assert_eq!(kept, [copy("a", Side::A, 1)]);
    let (none, _) = review(&plan, "q\n").await;
    assert!(none.is_empty());
    assert!(printed.contains(": b"));
}

#[tokio::test]
async fn a_closed_input_is_a_quit() {
    let plan = actions(vec![copy("a", Side::A, 1)]);
    let (kept, _) = review(&plan, "").await;
    assert!(kept.is_empty());
}

fn two_sided() -> Plan {
    Plan {
        actions: vec![],
        conflicts: vec![conflict("c", Some(created(3)), Some(created(7)))],
    }
}

#[tokio::test]
async fn a_two_sided_conflict_is_resolved_by_direction() {
    let (keep_a, printed) = review(&two_sided(), "1\n").await;
    assert_eq!(keep_a, [copy("c", Side::A, 3)]);
    assert!(
        printed.contains("[1] keep A (copy A -> B)  [2] keep B (copy B -> A)"),
        "{printed}"
    );
    let (keep_b, _) = review(&two_sided(), "2\n").await;
    assert_eq!(keep_b, [copy("c", Side::B, 7)]);
    let (skipped, _) = review(&two_sided(), "s\n").await;
    assert!(skipped.is_empty());
}

#[tokio::test]
async fn keeping_a_deleted_side_deletes_the_other() {
    let plan = Plan {
        actions: vec![],
        conflicts: vec![conflict("c", Some(Status::Deleted), Some(created(7)))],
    };
    let (kept, printed) = review(&plan, "1\n").await;
    assert_eq!(
        kept,
        [Action::Delete {
            path: path("c"),
            on: Side::B
        }]
    );
    assert!(printed.contains("[1] keep A (delete on B)"), "{printed}");
}

#[tokio::test]
async fn a_one_sided_conflict_offers_only_its_one_direction() {
    for (a, b, direction, from) in [
        (None, Some(created(4)), "copy B -> A", Side::B),
        (Some(created(4)), None, "copy A -> B", Side::A),
    ] {
        let plan = Plan {
            actions: vec![],
            conflicts: vec![conflict("c", a, b)],
        };
        let (refused, _) = review(&plan, "1\n").await;
        assert!(
            refused.is_empty(),
            "1 is not a key for a one-sided conflict"
        );
        let (kept, printed) = review(&plan, "y\n").await;
        assert_eq!(kept, [copy("c", from, 4)]);
        assert!(
            printed.contains(&format!("[y] accept ({direction})")),
            "{printed}"
        );
    }
}

#[tokio::test]
async fn conflicts_are_asked_before_actions_and_accept_all_resolves_none() {
    let plan = Plan {
        actions: vec![copy("f", Side::A, 1)],
        conflicts: vec![
            conflict("c", Some(created(3)), Some(created(7))),
            conflict("d", Some(created(3)), Some(created(7))),
        ],
    };
    let (kept, printed) = review(&plan, "a\n").await;
    assert_eq!(kept, [copy("f", Side::A, 1)]);
    assert!(printed.contains("--- conflict: c"), "{printed}");
    assert!(!printed.contains("--- conflict: d"), "{printed}");
    assert!(
        !printed.contains("--- copy"),
        "accept all asked no more:\n{printed}"
    );
}

#[tokio::test]
async fn an_unrecognized_answer_is_asked_again() {
    let plan = actions(vec![copy("a", Side::A, 1)]);
    let (kept, printed) = review(&plan, "maybe\n Y \n").await;
    assert_eq!(kept, [copy("a", Side::A, 1)]);
    assert!(
        printed.contains("Not understood: \"maybe\". Enter one of: y/s/a/q."),
        "{printed}"
    );
}

#[tokio::test]
async fn the_legend_comes_before_the_first_prompt_and_an_empty_plan_asks_nothing() {
    let (_, printed) = review(&actions(vec![copy("a", Side::A, 1)]), "y\n").await;
    let legend = printed.find("Interactive review (SPEC §11.3)").unwrap();
    assert!(legend < printed.find("--- copy A -> B: a").unwrap());
    let (kept, silent) = review(&Plan::default(), "").await;
    assert!(kept.is_empty() && silent.is_empty());
}

#[tokio::test]
async fn batch_keeps_every_action_and_resolves_no_conflict() {
    let plan = Plan {
        actions: vec![copy("f", Side::A, 1)],
        conflicts: vec![conflict("c", Some(created(3)), Some(created(7)))],
    };
    let batch = with_deadline("batch", BatchDecider.decide(&plan)).await;
    assert_eq!(batch, plan.actions);
    assert!(
        with_deadline("dry run", DryRunDecider.decide(&plan))
            .await
            .is_empty()
    );
}
