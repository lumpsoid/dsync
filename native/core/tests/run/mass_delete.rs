//! SPEC §10's delete guard through a run: a folder emptied on one side
//! stops the run before the other side loses its files, unless the
//! decider confirms or the run allows it.

use dsync_core::{BatchDecider, Decider, RunError, RunEvent};
use dsync_domain::{Action, Flags, MassDelete, Plan, Side, Tuning};

use crate::support::{Finished, Site, run, run_with, sync};

/// A batch decider that answers the delete guard with `confirm`, and
/// remembers what it was asked.
struct Confirming {
    confirm: bool,
    asked: Option<MassDelete>,
}

impl Decider for Confirming {
    async fn decide(&mut self, plan: &Plan) -> Vec<Action> {
        plan.actions.iter().map(|p| p.action.clone()).collect()
    }

    async fn confirm_deletes(&mut self, verdict: &MassDelete) -> bool {
        self.asked = Some(verdict.clone());
        self.confirm
    }
}

/// A pair synced over `count` files, then emptied on A.
async fn emptied_on_a(count: usize) -> Site {
    let site = Site::new();
    for index in 0..count {
        site.put(Side::A, &format!("f{index:02}"), "x");
    }
    assert_eq!(sync(&site).await.exit_code(), 0);
    for index in 0..count {
        std::fs::remove_file(site.file(Side::A, &format!("f{index:02}"))).unwrap();
    }
    site
}

fn verdicts(finished: &Finished) -> Vec<(&MassDelete, bool)> {
    finished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::MassDelete { verdict, allowed } => Some((verdict, *allowed)),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_batch_run_refuses_to_empty_the_other_side() {
    let site = emptied_on_a(12).await;

    let finished = sync(&site).await;

    let [(verdict, false)] = verdicts(&finished)[..] else {
        panic!("{:?}", finished.kinds());
    };
    let b = verdict.side(Side::B).unwrap();
    assert_eq!((b.deletes, b.archived), (12, 12));
    assert!(matches!(
        finished.errors()[..],
        [RunError::DeletesNotConfirmed(_)]
    ));
    assert_eq!(finished.exit_code(), 3);
    assert!(
        !finished.kinds().contains(&"action"),
        "{:?}",
        finished.kinds()
    );
    assert_eq!(site.tree(Side::B).len(), 12);
    assert!(!site.marker().exists());
    // Refused, not remembered: the next run asks again.
    assert_eq!(sync(&site).await.exit_code(), 3);
}

#[tokio::test]
async fn allow_mass_delete_reports_the_verdict_and_applies() {
    let site = emptied_on_a(12).await;
    let options = site.options_with(Flags {
        allow_mass_delete: true,
        ..Flags::default()
    });

    let finished = run_with(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &options,
        &mut BatchDecider,
        Tuning::DEFAULT,
    )
    .await;

    assert!(matches!(verdicts(&finished)[..], [(_, true)]));
    assert_eq!(finished.exit_code(), 0, "{:?}", finished.errors());
    assert!(site.tree(Side::B).is_empty());
}

#[tokio::test]
async fn a_decider_that_confirms_applies_and_one_that_declines_does_not() {
    let site = emptied_on_a(12).await;
    let mut declining = Confirming {
        confirm: false,
        asked: None,
    };
    let declined = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut declining,
    )
    .await;
    assert!(declining.asked.is_some());
    assert_eq!(declined.exit_code(), 3);
    assert_eq!(site.tree(Side::B).len(), 12);

    let mut confirming = Confirming {
        confirm: true,
        asked: None,
    };
    let confirmed = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut confirming,
    )
    .await;
    let asked = confirming.asked.unwrap();
    assert_eq!(asked.side(Side::B).map(|b| b.deletes), Some(12));
    assert_eq!(confirmed.exit_code(), 0, "{:?}", confirmed.errors());
    assert!(site.tree(Side::B).is_empty());
}

#[tokio::test]
async fn deletions_under_the_threshold_are_not_asked_about() {
    let site = emptied_on_a(9).await;
    let mut decider = Confirming {
        confirm: false,
        asked: None,
    };

    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut decider,
    )
    .await;

    assert!(decider.asked.is_none());
    assert!(verdicts(&finished).is_empty());
    assert_eq!(finished.exit_code(), 0, "{:?}", finished.errors());
    assert!(site.tree(Side::B).is_empty());
}

#[tokio::test]
async fn the_runs_own_thresholds_decide_when_it_asks() {
    let site = emptied_on_a(3).await;
    let options = site.options_with(Flags {
        mass_delete: Some((3, 50)),
        ..Flags::default()
    });
    let mut decider = Confirming {
        confirm: false,
        asked: None,
    };

    let finished = run_with(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &options,
        &mut decider,
        Tuning::DEFAULT,
    )
    .await;

    let asked = decider.asked.unwrap();
    assert_eq!(asked.side(Side::B).map(|b| b.deletes), Some(3));
    assert_eq!(finished.exit_code(), 3);
    assert_eq!(site.tree(Side::B).len(), 3);
}
