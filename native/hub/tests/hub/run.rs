//! Runs through the hub: started by command, steered by the head's
//! intents, and seen as the session's snapshots, the plan folded in as
//! the head does - the phase, the review and the outcome all decided here.

use dsync_core::ProfileStore;
use dsync_domain::{DIR_LEAF, Location, Platform, ProfileName, ReplicaLocation};
use hub::signals::{CoreCommand, ReplyResult, RunIntent, RunTarget};
use hub::views::{
    ActionChoiceView, ActionView, ConflictChoiceView, EntryStatusView, RunPhaseView,
    RunStandingView,
};

use crate::support::{FoldedRunView, Head, one_entry, read, write};

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
            &one_entry(local(a), local(b)),
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

fn steer(session: u64, intent: RunIntent) -> CoreCommand {
    CoreCommand::SteerRun { session, intent }
}

/// The phase's name, for asserting the order phases came in.
fn stage(view: &FoldedRunView) -> &'static str {
    match view.phase {
        RunPhaseView::Connecting => "connecting",
        RunPhaseView::Scanning => "scanning",
        RunPhaseView::Reviewing(_) => "reviewing",
        RunPhaseView::ConfirmingDeletes { .. } => "confirming deletes",
        RunPhaseView::Applying => "applying",
        RunPhaseView::Finished(_) => "finished",
        RunPhaseView::Stopped { .. } => "stopped",
        RunPhaseView::Paused { .. } => "paused",
        RunPhaseView::Failed { .. } => "failed",
        RunPhaseView::ReplicaBusy { .. } => "replica busy",
        RunPhaseView::DeletesDeclined => "deletes declined",
        RunPhaseView::NoSummary => "no summary",
        RunPhaseView::FinishedWithIssues { .. } => "finished with issues",
    }
}

/// The phases `views` went through, each once per stretch.
fn stages(views: &[FoldedRunView]) -> Vec<&'static str> {
    let mut stages: Vec<&'static str> = Vec::new();
    for view in views {
        let stage = stage(view);
        if stages.last() != Some(&stage) {
            stages.push(stage);
        }
    }
    stages
}

fn is(wanted: &'static str) -> impl Fn(&FoldedRunView) -> bool {
    move |view| stage(view) == wanted
}

/// The attempt is over: its timings report is in.
fn ended(view: &FoldedRunView) -> bool {
    view.timings.is_some()
}

fn path_of(action: &ActionView) -> &str {
    match action {
        ActionView::Copy { path, .. }
        | ActionView::CopyAside { path, .. }
        | ActionView::Delete { path, .. }
        | ActionView::CommitOnly { path } => path,
    }
}

fn index(at: usize) -> u32 {
    u32::try_from(at).unwrap_or_else(|error| panic!("{error}"))
}

/// Where the plan in `view` has the action on `path`.
fn row(view: &FoldedRunView, path: &str) -> u32 {
    let at = view
        .plan
        .iter()
        .position(|row| path_of(&row.proposal.action) == path)
        .unwrap_or_else(|| panic!("{path} is planned"));
    index(at)
}

#[tokio::test]
async fn the_head_reviews_the_plan_and_the_run_applies_what_it_kept() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/new.txt"), "hello");
    write(&head.path("a/skip.txt"), "not this one");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");

    let (session, started) = head.ok(start("local", false)).await;
    assert!(matches!(started, ReplyResult::Done));
    let mut views = head.run_until(session, is("reviewing")).await;
    let review = views
        .last()
        .unwrap_or_else(|| unreachable!("stopped at it"));
    assert!(review.connected_at_ms.is_some());
    assert!(review.replicas.as_ref().is_some_and(|replicas| {
        replicas.a.last_commit_ms.is_none() && replicas.b.last_commit_ms.is_none()
    }));
    assert_eq!(review.plan.len(), 2);
    let skip = row(review, "skip.txt");

    let skipping = steer(
        session,
        RunIntent::ChooseAction {
            index: skip,
            choice: ActionChoiceView::Skipped,
        },
    );
    assert!(matches!(head.ok(skipping).await.1, ReplyResult::Done));
    let tapped = head
        .run_until(session, |view| {
            view.plan
                .get(skip as usize)
                .is_some_and(|row| row.choice == ActionChoiceView::Skipped)
        })
        .await
        .pop()
        .unwrap_or_else(|| unreachable!("stopped at it"));
    let RunPhaseView::Reviewing(total) = &tapped.phase else {
        panic!("still reviewing");
    };
    assert_eq!((total.apply, total.skipped), (1, 1));
    assert_eq!(tapped.plan[skip as usize].choice, ActionChoiceView::Skipped);
    views.push(tapped);

    head.ok(steer(session, RunIntent::Confirm)).await;
    views.extend(head.run_until(session, ended).await);
    assert_eq!(
        stages(&views),
        [
            "connecting",
            "scanning",
            "reviewing",
            "applying",
            "finished"
        ]
    );
    let last = views.last().unwrap_or_else(|| unreachable!("ended"));
    let RunPhaseView::Finished(summary) = &last.phase else {
        panic!("expected a completed run");
    };
    assert_eq!((summary.applied, summary.skipped), (1, 1));
    assert_eq!((last.applied, last.failed), (1, 0));
    let new = &last.plan[row(last, "new.txt") as usize];
    assert!(
        new.outcome
            .as_ref()
            .is_some_and(|outcome| outcome.failure.is_none())
    );
    assert!(last.plan[skip as usize].outcome.is_none());
    assert!(
        last.timings
            .as_deref()
            .is_some_and(|timings| timings.contains("run:"))
    );
    assert_eq!(read(&head.path("b/new.txt")), "hello");
    assert!(!head.path("b/skip.txt").exists());

    // The session is over: nothing answers to it any more.
    let over = head.failure(steer(session, RunIntent::Stop)).await;
    assert!(over.contains("no run"), "{over}");

    // The run left both sides' archives; clearing the pair removes both.
    let ReplyResult::Archives(archives) = head.ok(CoreCommand::ListArchives).await.1 else {
        panic!("expected the archives");
    };
    assert_eq!(archives.len(), 2);
    let entry_id = archives[0].entry_id.clone();
    assert!(archives.iter().all(|archive| archive.entry_id == entry_id));
    let clear = CoreCommand::ClearArchive { entry_id };
    let ReplyResult::Archives(left) = head.ok(clear).await.1 else {
        panic!("expected the archives");
    };
    assert!(left.is_empty());
}

#[tokio::test]
async fn the_head_reverses_an_action_and_keeps_both_sides_of_a_conflict() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/x.txt"), "one");
    write(&head.path("a/n.md"), "base");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");

    // A first run keeps everything, so both sides share a baseline.
    let (session, _) = head.ok(start("local", false)).await;
    head.run_until(session, is("reviewing")).await;
    head.ok(steer(session, RunIntent::AcceptAll)).await;
    head.run_until(session, ended).await;
    assert_eq!(read(&head.path("b/x.txt")), "one");

    // A changes x.txt; both sides change n.md.
    write(&head.path("a/x.txt"), "two, longer");
    write(&head.path("a/n.md"), "mine, edited");
    write(&head.path("b/n.md"), "theirs, edited too");
    let (session, _) = head.ok(start("local", false)).await;
    let review = head
        .run_until(session, is("reviewing"))
        .await
        .pop()
        .unwrap_or_else(|| unreachable!("stopped at it"));
    let x = row(&review, "x.txt");
    let proposal = &review.plan[x as usize].proposal;
    assert!(matches!(proposal.action, ActionView::Copy { .. }));
    assert_eq!(proposal.reverse_bytes, Some(3));
    let [conflict] = &review.conflicts[..] else {
        panic!("one conflict");
    };
    assert_eq!(conflict.conflict.path, "n.md");
    assert!(conflict.offered.contains(&ConflictChoiceView::KeepBoth));

    let reverse = RunIntent::ChooseAction {
        index: x,
        choice: ActionChoiceView::Reversed,
    };
    head.ok(steer(session, reverse)).await;
    let keep_both = RunIntent::ChooseConflict {
        index: 0,
        choice: ConflictChoiceView::KeepBoth,
    };
    head.ok(steer(session, keep_both)).await;
    head.ok(steer(session, RunIntent::Confirm)).await;
    let last = head
        .run_until(session, ended)
        .await
        .pop()
        .unwrap_or_else(|| unreachable!("ended"));
    let RunPhaseView::Finished(summary) = &last.phase else {
        panic!("expected a completed run");
    };
    assert_eq!((summary.applied, summary.conflicts), (2, 1));
    assert_eq!((last.applied, last.failed), (2, 0));
    // The conflict's row carries what its choice applied: the copy aside.
    assert!(matches!(
        last.conflicts[0]
            .outcome
            .as_ref()
            .map(|outcome| &outcome.action),
        Some(ActionView::CopyAside { .. })
    ));

    // The reversal put B's version back over A's.
    assert_eq!(read(&head.path("a/x.txt")), "one");
    assert_eq!(read(&head.path("b/x.txt")), "one");
    // B's n.md sits beside A's, named from B's label ("b") and its mtime;
    // the conflict itself is left as it was.
    let aside: Vec<String> = std::fs::read_dir(head.path("a"))
        .unwrap_or_else(|error| panic!("{error}"))
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .filter(|name| name.starts_with("n.dsync-copy-from-b-") && name.ends_with(".md"))
        .collect();
    assert_eq!(aside.len(), 1, "{aside:?}");
    assert_eq!(
        read(&head.path(&format!("a/{}", aside[0]))),
        "theirs, edited too"
    );
    assert_eq!(read(&head.path("a/n.md")), "mine, edited");
    assert_eq!(read(&head.path("b/n.md")), "theirs, edited too");
}

#[tokio::test]
async fn emptying_one_side_asks_the_head_and_a_resume_asks_again() {
    let mut head = Head::new("studio").await;
    for index in 0..12 {
        write(&head.path(&format!("a/f{index:02}")), "x");
    }
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");
    let (first, _) = head.ok(start("local", false)).await;
    head.run_until(first, is("reviewing")).await;
    head.ok(steer(first, RunIntent::AcceptAll)).await;
    head.run_until(first, ended).await;
    for index in 0..12 {
        std::fs::remove_file(head.path(&format!("a/f{index:02}")))
            .unwrap_or_else(|error| panic!("{error}"));
    }
    let remaining = |head: &Head| {
        std::fs::read_dir(head.path("b"))
            .unwrap_or_else(|error| panic!("{error}"))
            .count()
    };

    let (session, _) = head.ok(start("local", false)).await;
    head.run_until(session, is("reviewing")).await;
    head.ok(steer(session, RunIntent::AcceptAll)).await;
    let asking = head
        .run_until(session, is("confirming deletes"))
        .await
        .pop()
        .unwrap_or_else(|| unreachable!("stopped at it"));
    let RunPhaseView::ConfirmingDeletes { sides } = &asking.phase else {
        unreachable!("confirming");
    };
    assert_eq!(
        sides.iter().map(|side| side.deletes).collect::<Vec<_>>(),
        [12]
    );
    let answer = |proceed| steer(session, RunIntent::AnswerDeletes { proceed });
    assert!(matches!(head.ok(answer(false)).await.1, ReplyResult::Done));
    let declined = head.run_until(session, ended).await;
    assert_eq!(
        stages(&declined),
        ["confirming deletes", "deletes declined"]
    );
    assert_eq!(remaining(&head), 12);

    // Resume runs the same target again in the same session, and asks
    // again.
    head.ok(steer(session, RunIntent::Resume)).await;
    let again = head.run_until(session, is("reviewing")).await;
    assert_eq!(stage(&again[0]), "connecting");
    assert!(again[0].plan.is_empty(), "a new attempt shows nothing old");
    head.ok(steer(session, RunIntent::AcceptAll)).await;
    head.run_until(session, is("confirming deletes")).await;
    head.ok(answer(true)).await;
    let confirmed = head.run_until(session, ended).await;
    assert!(matches!(
        confirmed.last().map(|view| &view.phase),
        Some(RunPhaseView::Finished(summary)) if summary.applied == 12
    ));
    assert_eq!(remaining(&head), 0);
}

#[tokio::test]
async fn a_dry_run_asks_nothing_and_applies_nothing() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/new.txt"), "hello");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");
    let (session, _) = head.ok(start("local", true)).await;
    let views = head.run_until(session, ended).await;
    assert_eq!(stages(&views), ["connecting", "scanning", "finished"]);
    let last = views.last().unwrap_or_else(|| unreachable!("ended"));
    assert!(last.dry_run);
    assert_eq!(last.plan.len(), 1);
    assert!(matches!(
        &last.phase,
        RunPhaseView::Finished(summary) if summary.applied == 0 && summary.skipped == 1
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
    head.run_until(session, is("reviewing")).await;
    assert!(matches!(
        head.ok(steer(session, RunIntent::Stop)).await.1,
        ReplyResult::Done
    ));
    let views = head.run_until(session, ended).await;
    assert!(matches!(
        views.last().map(|view| &view.phase),
        Some(RunPhaseView::Stopped { completed: 0 })
    ));
    assert!(!head.path("b/new.txt").exists());
}

#[tokio::test]
async fn a_paused_run_resumes_when_the_app_comes_back() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/new.txt"), "hello");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");
    let (session, _) = head.ok(start("local", false)).await;
    head.run_until(session, is("reviewing")).await;
    head.ok(steer(session, RunIntent::Pause)).await;
    head.run_until(session, is("paused")).await;
    assert!(!head.path("b/new.txt").exists());

    head.ok(steer(session, RunIntent::Foreground)).await;
    head.run_until(session, is("reviewing")).await;
    head.ok(steer(session, RunIntent::Confirm)).await;
    let views = head.run_until(session, ended).await;
    assert_eq!(
        stage(views.last().unwrap_or_else(|| unreachable!("ended"))),
        "finished"
    );
    assert_eq!(read(&head.path("b/new.txt")), "hello");
}

#[tokio::test]
async fn leaving_mid_review_stops_the_run_and_ends_the_session() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/new.txt"), "hello");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");
    let (session, _) = head.ok(start("local", false)).await;
    head.run_until(session, is("reviewing")).await;
    head.ok(steer(session, RunIntent::Close)).await;
    head.run_until(session, ended).await;
    let over = head.failure(steer(session, RunIntent::Resume)).await;
    assert!(over.contains("no run"), "{over}");
    assert!(!head.path("b/new.txt").exists());
}

#[tokio::test]
async fn a_target_that_does_not_resolve_is_the_session_s_failure() {
    let mut head = Head::new("studio").await;
    let (session, started) = head.ok(start("nothing-here", false)).await;
    assert!(matches!(started, ReplyResult::Done));
    let views = head.run_until(session, is("failed")).await;
    assert_eq!(stages(&views), ["connecting", "failed"]);
    let RunPhaseView::Failed { message } = &views[1].phase else {
        unreachable!("failed");
    };
    assert!(!message.is_empty());
    // Waiting on a resume, which resolves the target again.
    head.ok(steer(session, RunIntent::Resume)).await;
    let again = head.run_until(session, is("failed")).await;
    assert_eq!(stages(&again), ["connecting", "failed"]);
    head.ok(steer(session, RunIntent::Close)).await;
}

/// Saves `name` as a profile of one local folder entry per pair of leaves
/// under the head's temp dir.
fn entries_profile(head: &Head, name: &str, pairs: &[(&str, &str)]) {
    let text: String = pairs
        .iter()
        .map(|(a, b)| {
            format!(
                "[[entries]]\na = {:?}\nb = {:?}\n",
                head.path_text(a),
                head.path_text(b)
            )
        })
        .collect();
    let profiles = head.path("support").join(DIR_LEAF).join("profiles");
    write(&profiles.join(format!("{name}.toml")), &text);
}

fn statuses(view: &FoldedRunView) -> Vec<EntryStatusView> {
    view.entries
        .iter()
        .map(|entry| entry.status.clone())
        .collect()
}

/// Every snapshot but the last is live: no entry ends the session.
fn live_until_the_end(views: &[FoldedRunView]) {
    let (_, running) = views
        .split_last()
        .unwrap_or_else(|| unreachable!("some views"));
    assert!(
        running
            .iter()
            .all(|view| view.standing == RunStandingView::Live),
        "{:?}",
        stages(running)
    );
}

#[tokio::test]
async fn a_profile_s_entries_run_in_turn_and_a_missing_one_is_skipped_for_the_rest() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/one.txt"), "one");
    write(&head.path("c/two.txt"), "two");
    for leaf in ["b", "d"] {
        std::fs::create_dir_all(head.path(leaf)).unwrap_or_else(|error| panic!("{error}"));
    }
    entries_profile(&head, "two", &[("a", "b"), ("c", "d")]);

    let (session, _) = head.ok(start("two", false)).await;
    let mut views = head.run_until(session, is("reviewing")).await;
    let first = views
        .last()
        .unwrap_or_else(|| unreachable!("stopped at it"));
    assert_eq!(first.current, Some(0));
    assert_eq!(first.entries.len(), 2);
    assert_eq!(first.entries[1].local_root, head.path_text("c"));
    assert_eq!(first.entries[1].remote_root, head.path_text("d"));
    head.ok(steer(session, RunIntent::AcceptAll)).await;
    views.extend(
        head.run_until(session, |view| {
            is("reviewing")(view) && view.current == Some(1)
        })
        .await,
    );
    head.ok(steer(session, RunIntent::AcceptAll)).await;
    views.extend(head.run_until(session, ended).await);
    live_until_the_end(&views);
    let done = views.last().unwrap_or_else(|| unreachable!("ended"));
    assert!(matches!(
        &done.phase,
        RunPhaseView::Finished(summary) if summary.applied == 2
    ));
    assert_eq!(done.standing, RunStandingView::Over);
    assert_eq!(
        statuses(done),
        [EntryStatusView::Synced, EntryStatusView::Synced]
    );
    assert_eq!(read(&head.path("b/one.txt")), "one");
    assert_eq!(read(&head.path("d/two.txt")), "two");

    // The first entry's synced folder goes; the second has more to sync.
    std::fs::remove_dir_all(head.path("a")).unwrap_or_else(|error| panic!("{error}"));
    write(&head.path("c/more.txt"), "more");
    write(&head.path("c/skip.txt"), "not this one");
    let (session, _) = head.ok(start("two", false)).await;
    let mut views = head.run_until(session, is("reviewing")).await;
    let review = views
        .last()
        .unwrap_or_else(|| unreachable!("stopped at it"));
    assert_eq!(review.current, Some(1));
    assert!(matches!(
        statuses(review)[0],
        EntryStatusView::Skipped { ref reason } if reason.contains(&head.path_text("a"))
    ));
    // The intents index the running entry's plan.
    let skip = row(review, "skip.txt");
    let skipping = RunIntent::ChooseAction {
        index: skip,
        choice: ActionChoiceView::Skipped,
    };
    head.ok(steer(session, skipping)).await;
    head.ok(steer(session, RunIntent::Confirm)).await;
    views.extend(head.run_until(session, ended).await);
    live_until_the_end(&views);
    let done = views.last().unwrap_or_else(|| unreachable!("ended"));
    let RunPhaseView::FinishedWithIssues { entries } = &done.phase else {
        panic!("finished with issues, not {}", stage(done));
    };
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].index, 0);
    assert_eq!(done.standing, RunStandingView::Resumable);
    assert_eq!(statuses(done)[1], EntryStatusView::Synced);
    assert_eq!(read(&head.path("d/more.txt")), "more");
    assert!(!head.path("d/skip.txt").exists());
    assert!(!head.path("a").exists(), "a synced root is never recreated");
    head.ok(steer(session, RunIntent::Close)).await;
}

#[tokio::test]
async fn a_pause_in_the_second_entry_resumes_from_the_first() {
    let mut head = Head::new("studio").await;
    write(&head.path("c/two.txt"), "two");
    for leaf in ["a", "b", "d"] {
        std::fs::create_dir_all(head.path(leaf)).unwrap_or_else(|error| panic!("{error}"));
    }
    entries_profile(&head, "two", &[("a", "b"), ("c", "d")]);
    let (session, _) = head.ok(start("two", false)).await;
    let second = |view: &FoldedRunView| is("reviewing")(view) && view.current == Some(1);
    head.run_until(session, second).await;
    head.ok(steer(session, RunIntent::Pause)).await;
    let paused = head.run_until(session, is("paused")).await;
    let paused = paused
        .last()
        .unwrap_or_else(|| unreachable!("stopped at it"));
    assert_eq!(paused.standing, RunStandingView::Resumable);
    assert!(!head.path("d/two.txt").exists());

    head.ok(steer(session, RunIntent::Foreground)).await;
    let again = head.run_until(session, second).await;
    assert_eq!(again[0].current, None);
    assert_eq!(
        statuses(&again[0]),
        [EntryStatusView::Pending, EntryStatusView::Pending]
    );
    let started = again
        .iter()
        .find_map(|view| view.current)
        .unwrap_or_else(|| unreachable!("the second entry started"));
    assert_eq!(started, 0, "the first entry runs again first");
    head.ok(steer(session, RunIntent::Confirm)).await;
    let views = head.run_until(session, ended).await;
    assert_eq!(
        stage(views.last().unwrap_or_else(|| unreachable!("ended"))),
        "finished"
    );
    assert_eq!(read(&head.path("d/two.txt")), "two");
}

/// Two entries whose roots differ as typed but nest once a symlink is
/// followed: refused before either runs, named by the profile.
#[cfg(unix)]
#[tokio::test]
async fn a_profile_whose_roots_nest_through_a_symlink_is_refused_by_name() {
    let mut head = Head::new("studio").await;
    for leaf in ["a/inner", "b", "d"] {
        std::fs::create_dir_all(head.path(leaf)).unwrap_or_else(|error| panic!("{error}"));
    }
    std::os::unix::fs::symlink(head.path("a"), head.path("link"))
        .unwrap_or_else(|error| panic!("{error}"));
    entries_profile(&head, "nested", &[("a", "b"), ("link/inner", "d")]);
    let (session, _) = head.ok(start("nested", false)).await;
    let views = head.run_until(session, is("failed")).await;
    let RunPhaseView::Failed { message } =
        &views.last().unwrap_or_else(|| unreachable!("failed")).phase
    else {
        unreachable!("failed");
    };
    assert!(
        message.starts_with("profile \"nested\": entries[0].a"),
        "{message}"
    );
    // Positive control: the second entry alone runs.
    entries_profile(&head, "inner", &[("link/inner", "d")]);
    let (session, _) = head.ok(start("inner", false)).await;
    let views = head.run_until(session, ended).await;
    assert_eq!(
        stage(views.last().unwrap_or_else(|| unreachable!("ended"))),
        "finished"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn a_run_whose_far_side_does_not_answer_fails_with_where_it_dialled() {
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
            &one_entry(parse(&head.path_text("a")), parse(&socket)),
        )
        .unwrap_or_else(|error| panic!("{error}"));
    let (session, _) = head.ok(start("far", false)).await;
    let views = head.run_until(session, is("failed")).await;
    assert_eq!(stages(&views), ["connecting", "failed"]);
    assert!(matches!(
        views.last().map(|view| &view.phase),
        Some(RunPhaseView::Failed { message }) if message.contains("nobody.sock")
    ));
}
