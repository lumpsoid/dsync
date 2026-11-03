//! SPEC §10's overwrite guard through a run: a folder whose files were all
//! rewritten - or emptied - on one side stops the run before the other
//! side's copies are overwritten, unless the decider confirms or the run
//! allows it with its own flag.

use dsync_core::{BatchDecider, Decider, Peek, Replica, RunError, RunEvent};
use dsync_domain::{Action, Flags, MassDelete, MassOverwrite, Plan, Side, Tuning};

use crate::run::support::{Finished, Site, run, run_with, sync};

/// A batch decider that answers the overwrite guard with `confirm`, and
/// remembers what it was asked.
struct Confirming {
    confirm: bool,
    asked: Option<MassOverwrite>,
}

impl Decider for Confirming {
    async fn decide<A: Replica, B: Replica>(
        &mut self,
        plan: &Plan,
        _: Peek<'_, A, B>,
    ) -> Vec<Action> {
        plan.actions.iter().map(|p| p.action.clone()).collect()
    }

    async fn confirm_deletes(&mut self, verdict: &MassDelete) -> bool {
        panic!("nothing here deletes: {verdict:?}")
    }

    async fn confirm_overwrites(&mut self, verdict: &MassOverwrite) -> bool {
        self.asked = Some(verdict.clone());
        self.confirm
    }
}

fn name(index: usize) -> String {
    format!("f{index:02}")
}

/// A pair synced over `count` files, then the first `rewritten` of them
/// rewritten on A to `text`.
async fn rewritten_on_a(count: usize, rewritten: usize, text: &str) -> Site {
    let site = Site::new();
    for index in 0..count {
        site.put(Side::A, &name(index), "plain");
    }
    assert_eq!(sync(&site).await.exit_code(), 0);
    for index in 0..rewritten {
        site.put(Side::A, &name(index), text);
    }
    site
}

fn verdicts(finished: &Finished) -> Vec<(&MassOverwrite, bool)> {
    finished
        .events
        .iter()
        .filter_map(|event| match event {
            RunEvent::MassOverwrite { verdict, allowed } => Some((verdict, *allowed)),
            _ => None,
        })
        .collect()
}

/// Whether every one of B's first `count` files still reads `text`.
fn b_reads(site: &Site, count: usize, text: &str) -> bool {
    (0..count).all(|index| {
        std::fs::read_to_string(site.file(Side::B, &name(index))).ok() == Some(text.into())
    })
}

#[tokio::test]
async fn a_batch_run_refuses_to_overwrite_most_of_the_other_side() {
    let site = rewritten_on_a(12, 12, "encrypted").await;

    let finished = sync(&site).await;

    let [(verdict, false)] = verdicts(&finished)[..] else {
        panic!("{:?}", finished.kinds());
    };
    let b = verdict.side(Side::B).unwrap();
    assert_eq!((b.overwrites, b.truncated, b.archived), (12, 0, 12));
    assert!(matches!(
        finished.errors()[..],
        [RunError::OverwritesNotConfirmed(_)]
    ));
    assert_eq!(finished.exit_code(), 3);
    assert!(
        !finished.kinds().contains(&"action"),
        "{:?}",
        finished.kinds()
    );
    assert!(b_reads(&site, 12, "plain"));
    assert!(!site.marker().exists());
    // Refused, not remembered: the next run asks again.
    assert_eq!(sync(&site).await.exit_code(), 3);
}

#[tokio::test]
async fn allow_mass_overwrite_reports_the_verdict_and_applies() {
    let site = rewritten_on_a(12, 12, "encrypted").await;
    let options = site.options_with(Flags {
        allow_mass_overwrite: true,
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
    assert!(b_reads(&site, 12, "encrypted"));
}

#[tokio::test]
async fn allow_mass_delete_does_not_allow_a_mass_overwrite() {
    let site = rewritten_on_a(12, 12, "encrypted").await;
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

    assert_eq!(finished.exit_code(), 3);
    assert!(b_reads(&site, 12, "plain"));
}

#[tokio::test]
async fn files_emptied_trip_it_in_a_big_folder() {
    let site = rewritten_on_a(40, 5, "").await;
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

    let asked = decider.asked.unwrap();
    let b = asked.side(Side::B).unwrap();
    assert_eq!((b.overwrites, b.truncated, b.archived), (5, 5, 40));
    assert_eq!(finished.exit_code(), 3);
    assert!(b_reads(&site, 5, "plain"));
}

#[tokio::test]
async fn a_decider_that_confirms_applies_and_overwrites_under_the_threshold_are_not_asked() {
    let site = rewritten_on_a(12, 12, "encrypted").await;
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
    assert!(confirming.asked.is_some());
    assert_eq!(confirmed.exit_code(), 0, "{:?}", confirmed.errors());
    assert!(b_reads(&site, 12, "encrypted"));

    let site = rewritten_on_a(20, 10, "edited").await;
    let mut declining = Confirming {
        confirm: false,
        asked: None,
    };
    let finished = run(
        &site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut declining,
    )
    .await;
    assert!(declining.asked.is_none());
    assert!(verdicts(&finished).is_empty());
    assert_eq!(finished.exit_code(), 0, "{:?}", finished.errors());
    assert!(b_reads(&site, 10, "edited"));
}
