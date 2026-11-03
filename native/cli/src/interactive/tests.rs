use dsync_core::{BatchDecider, Decider, DryRunDecider, Recall};
use dsync_domain::{Action, Plan, Side, Status};
use tokio::sync::watch;

use super::InteractiveDecider;
use crate::render::fixtures::{conflict, created, mass_delete, mass_overwrite, path, proposed};
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
    let (_shown, plan_shown) = watch::channel(1);
    let mut output = Vec::new();
    let mut decider = InteractiveDecider::new(script.as_bytes(), &mut output, plan_shown);
    let kept = with_deadline("the review", decider.review(plan)).await;
    drop(decider);
    (kept, String::from_utf8(output).unwrap())
}

fn actions(actions: Vec<Action>) -> Plan {
    Plan {
        actions: proposed(actions),
        conflicts: vec![],
    }
}

/// A profile's second entry reuses this decider; its plan is a fresh
/// `RunEvent::Plan` the renderer has not shown yet, so its review must wait
/// for its own count, not the one entry 1 already satisfied.
#[tokio::test]
async fn a_later_review_waits_for_its_own_plan_not_an_earlier_ones() {
    use std::time::Duration;

    let (shown, plan_shown) = watch::channel(1);
    let mut output = Vec::new();
    let mut decider = InteractiveDecider::new(&b"y\ny\n"[..], &mut output, plan_shown);

    // Entry 1: the channel already reads 1, so this proceeds at once.
    let first = actions(vec![copy("a", Side::A, 1)]);
    let kept = with_deadline("entry 1", decider.review(&first)).await;
    assert_eq!(kept, [copy("a", Side::A, 1)]);

    // Entry 2: nothing has bumped the count past 1 yet - a stale `true`
    // flag would answer this at once; the count must not.
    let second = actions(vec![copy("b", Side::A, 1)]);
    let waiting = decider.review(&second);
    tokio::pin!(waiting);
    let premature = tokio::time::timeout(Duration::from_millis(50), &mut waiting).await;
    assert!(
        premature.is_err(),
        "entry 2 answered before its plan was shown"
    );

    shown.send(2).unwrap();
    let kept = with_deadline("entry 2", waiting).await;
    assert_eq!(kept, [copy("b", Side::A, 1)]);
}

/// A re-dialled entry whose plan had not changed is answered without a
/// review, but its plan event was shown; entry 2's review must still wait
/// for entry 2's plan.
#[tokio::test]
async fn a_carried_plan_keeps_the_next_review_waiting_for_its_own_plan() {
    use std::time::Duration;

    let (shown, plan_shown) = watch::channel(1);
    let mut output = Vec::new();
    let mut decider = InteractiveDecider::new(&b"y\ny\n"[..], &mut output, plan_shown);

    // Entry 1, attempt 1: reviewed.
    let first = actions(vec![copy("a", Side::A, 1)]);
    let answer = with_deadline("entry 1", decider.review(&first)).await;
    // Entry 1, attempt 2: its plan is shown, and answered without a review.
    shown.send(2).unwrap();
    let recall = Recall::after(&first, &answer, &first).expect("a replayable answer");
    decider.carried(&first, &recall);

    // Entry 2: its plan is not shown yet.
    let second = actions(vec![copy("b", Side::A, 1)]);
    let waiting = decider.review(&second);
    tokio::pin!(waiting);
    let premature = tokio::time::timeout(Duration::from_millis(50), &mut waiting).await;
    assert!(
        premature.is_err(),
        "entry 2 answered before its plan was shown"
    );

    shown.send(3).unwrap();
    let kept = with_deadline("entry 2", waiting).await;
    assert_eq!(kept, [copy("b", Side::A, 1)]);
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
        actions: proposed(vec![copy("f", Side::A, 1)]),
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

/// The delete guard's answer to `script`, and what was printed.
async fn confirm(script: &str) -> (bool, String) {
    let (_shown, plan_shown) = watch::channel(1);
    let mut output = Vec::new();
    let mut decider = InteractiveDecider::new(script.as_bytes(), &mut output, plan_shown);
    let verdict = mass_delete(Side::B, 12, 12);
    let confirmed = with_deadline("the confirmation", decider.confirm_deletes(&verdict)).await;
    drop(decider);
    (confirmed, String::from_utf8(output).unwrap())
}

#[tokio::test]
async fn the_delete_guard_shows_the_count_and_a_sample_per_side() {
    let (_, printed) = confirm("n\n").await;
    assert!(
        printed.contains("on B: 12 of the 12 files it last synced"),
        "{printed}"
    );
    assert!(printed.contains("    f00\n"), "{printed}");
    assert!(printed.contains("    f04\n"), "{printed}");
    assert!(!printed.contains("f05"), "{printed}");
    assert!(printed.contains("and 7 more"), "{printed}");
    assert!(printed.contains("[y/N]"), "{printed}");
}

#[tokio::test]
async fn the_delete_guard_proceeds_only_on_yes() {
    assert!(confirm("y\n").await.0);
    assert!(confirm("YES\n").await.0);
    assert!(!confirm("n\n").await.0);
}

#[tokio::test]
async fn the_delete_guard_defaults_to_no() {
    assert!(!confirm("\n").await.0, "an empty line");
    assert!(!confirm("").await.0, "a closed input");
}

#[tokio::test]
async fn the_delete_guard_asks_again_when_not_understood() {
    let (confirmed, printed) = confirm("sure\ny\n").await;
    assert!(confirmed);
    assert!(printed.contains("Not understood: \"sure\""), "{printed}");
}

#[tokio::test]
async fn batch_and_dry_run_never_confirm_deletions() {
    let verdict = mass_delete(Side::A, 10, 10);
    assert!(!with_deadline("batch", BatchDecider.confirm_deletes(&verdict)).await);
    assert!(!with_deadline("dry run", DryRunDecider.confirm_deletes(&verdict)).await);
}

/// The overwrite guard's answer to `script`, and what was printed.
async fn confirm_overwrites(script: &str) -> (bool, String) {
    let (_shown, plan_shown) = watch::channel(1);
    let mut output = Vec::new();
    let mut decider = InteractiveDecider::new(script.as_bytes(), &mut output, plan_shown);
    let verdict = mass_overwrite(Side::B, 12, 1, 12);
    let confirmed = with_deadline("the confirmation", decider.confirm_overwrites(&verdict)).await;
    drop(decider);
    (confirmed, String::from_utf8(output).unwrap())
}

#[tokio::test]
async fn the_overwrite_guard_shows_the_counts_and_proceeds_only_on_yes() {
    let (confirmed, printed) = confirm_overwrites("y\n").await;
    assert!(confirmed);
    assert!(
        printed.contains("on B: 12 of the 12 files it last synced, 1 of them emptied to 0 bytes"),
        "{printed}"
    );
    assert!(printed.contains("    f11\n"), "{printed}");
    assert!(printed.contains("and 7 more"), "{printed}");
    assert!(
        printed.contains("Apply these overwrites? [y/N]"),
        "{printed}"
    );
    assert!(!confirm_overwrites("\n").await.0, "an empty line");
    assert!(!confirm_overwrites("").await.0, "a closed input");
}

#[tokio::test]
async fn batch_and_dry_run_never_confirm_overwrites() {
    let verdict = mass_overwrite(Side::A, 10, 0, 10);
    assert!(!with_deadline("batch", BatchDecider.confirm_overwrites(&verdict)).await);
    assert!(!with_deadline("dry run", DryRunDecider.confirm_overwrites(&verdict)).await);
}
