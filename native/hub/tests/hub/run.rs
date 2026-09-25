//! Runs through the hub: started by command, the plan decided over
//! signals, the run's story on its session's stream.

use dsync_core::ProfileStore;
use dsync_domain::{DIR_LEAF, Location, Platform, Profile, ProfileName, ReplicaLocation};
use hub::signals::{CoreCommand, ReplyResult, RunDecision, RunTarget, RunUpdateBody};
use hub::views::{ActionView, RunEndView, StoppedView};

use crate::support::{Head, read, write};

/// Saves `name` as a local-to-local profile over `a` and `b` under the
/// head's temp dir, as the CLI would write one.
fn local_profile(head: &Head, name: &str, a: &str, b: &str) {
    let local = |leaf: &str| {
        ReplicaLocation::new(
            Location::parse(&head.path_text(leaf), Platform::HOST)
                .unwrap_or_else(|error| panic!("{error}")),
            None,
        )
        .unwrap_or_else(|error| panic!("{error}"))
    };
    ProfileStore::new(head.path("support").join(DIR_LEAF))
        .save(
            &ProfileName::parse(name).unwrap_or_else(|error| panic!("{error}")),
            &Profile::new(local(a), local(b)),
        )
        .unwrap_or_else(|error| panic!("{error}"));
}

fn start(name: &str, dry_run: bool) -> CoreCommand {
    CoreCommand::StartRun {
        target: RunTarget::Profile {
            name: name.to_owned(),
        },
        dry_run,
        address: None,
    }
}

fn is_ended(update: &RunUpdateBody) -> bool {
    matches!(update, RunUpdateBody::Ended(_))
}

fn is_plan(update: &RunUpdateBody) -> bool {
    matches!(update, RunUpdateBody::Plan { .. })
}

#[tokio::test]
async fn the_head_decides_the_plan_and_the_run_applies_what_it_kept() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/new.txt"), "hello");
    write(&head.path("a/skip.txt"), "not this one");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");

    let (session, started) = head.ok(start("local", false)).await;
    let ReplyResult::RunStarted(started) = started else {
        panic!("expected the run to start");
    };
    assert_eq!(started.profile_id.len(), 32);

    let before = head.run_until(session, is_plan).await;
    assert!(matches!(before[0], RunUpdateBody::Connected { ref peers } if peers.is_empty()));
    assert!(before.iter().any(|update| matches!(
        update,
        RunUpdateBody::Replicas { a, b, .. } if a.last_commit_ms.is_none() && b.last_commit_ms.is_none()
    )));
    let Some(RunUpdateBody::Plan {
        actions,
        awaiting_decision,
        ..
    }) = before.last()
    else {
        unreachable!("stopped at the plan");
    };
    assert!(*awaiting_decision);
    let path = |action: &ActionView| match action {
        ActionView::Copy { path, .. }
        | ActionView::CopyAside { path, .. }
        | ActionView::Delete { path, .. }
        | ActionView::CommitOnly { path } => path.clone(),
    };
    let keep: Vec<u32> = actions
        .iter()
        .enumerate()
        .filter(|(_, action)| path(action) == "new.txt")
        .filter_map(|(index, _)| u32::try_from(index).ok())
        .collect();
    assert_eq!(keep.len(), 1);

    let decide = CoreCommand::DecideRun {
        session,
        decision: RunDecision {
            keep,
            resolve: Vec::new(),
        },
    };
    assert!(matches!(head.ok(decide).await.1, ReplyResult::Done));
    let after = head.run_until(session, is_ended).await;
    let applied: Vec<_> = after
        .iter()
        .filter_map(|update| match update {
            RunUpdateBody::Applied { results, .. } => Some(results),
            _ => None,
        })
        .flatten()
        .collect();
    assert_eq!(applied.len(), 1);
    assert!(applied[0].failure.is_none());
    let Some(RunUpdateBody::Ended(RunEndView::Ran {
        summary: Some(summary),
        errored: false,
        stopped: None,
        timings,
    })) = after.last()
    else {
        panic!("expected a completed run");
    };
    assert_eq!((summary.applied, summary.skipped), (1, 1));
    assert!(timings.contains("run:"), "{timings}");
    assert_eq!(read(&head.path("b/new.txt")), "hello");
    assert!(!head.path("b/skip.txt").exists());

    // The session is over: nothing answers to it any more.
    let over = head.failure(CoreCommand::StopRun { session }).await;
    assert!(over.contains("no run"), "{over}");

    // The run left both sides' archives; clearing the pair removes both.
    let ReplyResult::Archives(archives) = head.ok(CoreCommand::ListArchives).await.1 else {
        panic!("expected the archives");
    };
    assert_eq!(archives.len(), 2);
    assert!(
        archives
            .iter()
            .all(|archive| archive.profile_id == started.profile_id)
    );
    let clear = CoreCommand::ClearArchive {
        profile_id: started.profile_id.clone(),
    };
    let ReplyResult::Archives(left) = head.ok(clear).await.1 else {
        panic!("expected the archives");
    };
    assert!(left.is_empty());
}

#[tokio::test]
async fn a_dry_run_asks_nothing_and_applies_nothing() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/new.txt"), "hello");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");
    let (session, _) = head.ok(start("local", true)).await;
    let updates = head.run_until(session, is_ended).await;
    assert!(updates.iter().any(|update| matches!(
        update,
        RunUpdateBody::Plan { awaiting_decision: false, actions, .. } if actions.len() == 1
    )));
    assert!(matches!(
        updates.last(),
        Some(RunUpdateBody::Ended(RunEndView::Ran { summary: Some(summary), .. }))
            if summary.applied == 0 && summary.skipped == 1
    ));
    assert!(!head.path("b/new.txt").exists());
}

#[tokio::test]
async fn a_run_stopped_while_the_head_decides_applies_nothing_and_ends_stopped() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/new.txt"), "hello");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");
    let (session, _) = head.ok(start("local", false)).await;
    head.run_until(session, is_plan).await;
    assert!(matches!(
        head.ok(CoreCommand::StopRun { session }).await.1,
        ReplyResult::Done
    ));
    let updates = head.run_until(session, is_ended).await;
    assert!(matches!(
        updates.last(),
        Some(RunUpdateBody::Ended(RunEndView::Ran {
            stopped: Some(StoppedView::Gracefully),
            ..
        }))
    ));
    assert!(!head.path("b/new.txt").exists());
}

#[tokio::test]
async fn a_run_that_cannot_start_is_the_reply() {
    let mut head = Head::new("studio").await;
    let unknown = head.failure(start("nothing-here", false)).await;
    assert!(!unknown.is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn a_run_whose_far_side_does_not_answer_ends_not_connected() {
    let mut head = Head::new("studio").await;
    std::fs::create_dir_all(head.path("a")).unwrap_or_else(|error| panic!("{error}"));
    let parse = |raw: &str| {
        ReplicaLocation::new(
            Location::parse(raw, Platform::HOST).unwrap_or_else(|error| panic!("{error}")),
            None,
        )
        .unwrap_or_else(|error| panic!("{error}"))
    };
    let socket = format!("unix://{}:/srv/x", head.path_text("nobody.sock"));
    ProfileStore::new(head.path("support").join(DIR_LEAF))
        .save(
            &ProfileName::parse("far").unwrap_or_else(|error| panic!("{error}")),
            &Profile::new(parse(&head.path_text("a")), parse(&socket)),
        )
        .unwrap_or_else(|error| panic!("{error}"));
    let (session, _) = head.ok(start("far", false)).await;
    let updates = head.run_until(session, is_ended).await;
    assert!(matches!(
        &updates[..],
        [RunUpdateBody::Ended(RunEndView::NotConnected { message })] if message.contains("nobody.sock")
    ));
}
