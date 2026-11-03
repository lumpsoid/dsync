use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use dsync_core::{ActionFailure, LockError, ReplicaError, RunError, RunEvent};
use dsync_domain::{
    Action, Locality, MissingReplicaRoot, Plan, ReplicaInfo, ReplicaOp, ReplicaRoot, RunSummary,
    ScanTally, Side, SkippedPath, SkippedReason, Status, Unchanged, Verbosity,
};

use super::HumanRenderer;
use crate::render::fixtures::{
    self, PROFILE_ID, clock, conflict, created, mass_delete, path, proposed, unchanged,
};
use crate::render::{RunName, RunView};

/// What one renderer printed: stdout, then stderr.
fn rendered(view: &RunView, verbosity: Verbosity, events: &[RunEvent]) -> (String, String) {
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let mut renderer = HumanRenderer::new(&mut out, &mut err, verbosity, view.clone(), clock());
    for event in events {
        renderer.render(event);
    }
    (
        String::from_utf8(out).unwrap(),
        String::from_utf8(err).unwrap(),
    )
}

fn out(verbosity: Verbosity, events: &[RunEvent]) -> String {
    rendered(&fixtures::view(), verbosity, events).0
}

fn copy(at: &str, from: Side) -> Action {
    Action::Copy {
        path: path(at),
        from,
        bytes: 5,
    }
}

fn plan_event(actions: Vec<Action>, exceeds_warn_size: bool) -> RunEvent {
    RunEvent::Plan {
        plan: Plan {
            actions: proposed(actions),
            conflicts: vec![],
        },
        exceeds_warn_size,
    }
}

fn summary() -> RunEvent {
    RunEvent::Summary(RunSummary {
        applied: 1,
        skipped: 2,
        conflicts: 3,
        failed: 4,
        unreadable: 5,
    })
}

fn info(last_commit: Option<std::time::SystemTime>) -> ReplicaInfo {
    ReplicaInfo {
        last_commit,
        archived_files: 0,
        archive_path: Some("/state/x-a.jsonl".into()),
        root: ReplicaRoot::Present,
    }
}

fn replicas(a: Option<u64>, b: Option<u64>, last_run_unfinished: bool) -> RunEvent {
    let at = |ago: Option<u64>| ago.map(|seconds| clock().now - Duration::from_secs(seconds));
    RunEvent::Replicas {
        a: info(at(a)),
        b: info(at(b)),
        last_run_unfinished,
    }
}

fn skipped(side: Side, reason: SkippedReason, detail: &str) -> RunEvent {
    RunEvent::Skipped {
        side,
        skipped: SkippedPath::new(path("link"), reason, detail),
    }
}

fn scan_tally() -> RunEvent {
    RunEvent::ScanTally {
        a: ScanTally {
            metadata_matched: 3,
            hash_matched: 2,
            created: 1,
            ..ScanTally::default()
        },
        b: ScanTally::default(),
    }
}

fn held_lock() -> RunEvent {
    RunEvent::Error(RunError::Replica {
        side: Side::A,
        op: ReplicaOp::Lock,
        source: Arc::new(ReplicaError::Lock(LockError::Held {
            path: PathBuf::from("/state/a.lock"),
        })),
    })
}

#[test]
fn quiet_prints_only_the_summary_line() {
    let text = out(
        Verbosity::Quiet,
        &[
            replicas(None, None, false),
            scan_tally(),
            skipped(Side::A, SkippedReason::Symlink, "broken link"),
            RunEvent::Conflict(conflict("c", Some(created(1)), Some(created(2)))),
            plan_event(vec![copy("f", Side::A)], true),
            RunEvent::Action(copy("f", Side::A)),
            RunEvent::Result {
                action: copy("f", Side::A),
                outcome: Ok(()),
            },
            RunEvent::Progress {
                completed: 1,
                total: 1,
            },
            summary(),
        ],
    );
    assert_eq!(
        text,
        "summary: applied=1 skipped=2 conflicts=3 failed=4 unreadable=5\n"
    );
}

#[test]
fn an_error_goes_to_stderr_at_every_verbosity() {
    for verbosity in [Verbosity::Quiet, Verbosity::Normal, Verbosity::Verbose] {
        let (out, err) = rendered(
            &fixtures::view(),
            verbosity,
            &[RunEvent::Error(RunError::Replica {
                side: Side::B,
                op: ReplicaOp::Scan,
                source: Arc::new(ReplicaError::NoScan),
            })],
        );
        assert_eq!(out, "");
        assert!(err.starts_with("error: replica b: scan failed"), "{err}");
    }
}

#[test]
fn the_plan_table_lists_every_action() {
    let text = out(
        Verbosity::Normal,
        &[plan_event(
            vec![
                copy("one", Side::A),
                copy("two", Side::B),
                Action::Delete {
                    path: path("three"),
                    on: Side::B,
                },
                Action::CommitOnly { path: path("four") },
            ],
            false,
        )],
    );
    assert_eq!(
        text,
        "plan: 4 action(s), 0 conflict(s), 10 byte(s) to transfer\n  copy A→B  one\n  copy \
         B→A  two\n  delete on B  three\n  commit only  four\n"
    );
}

#[test]
fn a_conflict_names_each_side_status() {
    let text = out(
        Verbosity::Normal,
        &[
            RunEvent::Conflict(conflict("both", Some(created(1)), Some(Status::Deleted))),
            RunEvent::Conflict(conflict("half", None, Some(created(2)))),
        ],
    );
    assert_eq!(
        text,
        "conflict  both  (A: created, B: deleted)\nconflict  half  (A: absent, B: created)\n"
    );
}

#[test]
fn normal_hides_the_reason_behind_a_status_and_verbose_shows_it() {
    let event = RunEvent::Conflict(conflict(
        "c",
        Some(unchanged(Unchanged::MetadataMatched)),
        Some(unchanged(Unchanged::HashMatched)),
    ));
    assert_eq!(
        out(Verbosity::Normal, std::slice::from_ref(&event)),
        "conflict  c  (A: unchanged, B: unchanged)\n"
    );
    let verbose = out(Verbosity::Verbose, &[event]);
    assert!(
        verbose.contains("A: unchanged [size/mtime matched archive, not rehashed]"),
        "{verbose}"
    );
    assert!(
        verbose.contains("B: unchanged [size/mtime drifted, rehash matched archive]"),
        "{verbose}"
    );
}

#[test]
fn a_skipped_path_says_which_side_why_and_whether_it_synced() {
    let text = out(
        Verbosity::Normal,
        &[
            skipped(Side::A, SkippedReason::Symlink, "broken link"),
            skipped(Side::B, SkippedReason::Symlink, "no follow rule"),
            skipped(Side::A, SkippedReason::Unreadable, "Permission denied"),
            skipped(Side::B, SkippedReason::CaseFoldCollision, "folds onto LINK"),
            skipped(Side::A, SkippedReason::SpecialFile, "fifo"),
            RunEvent::Skipped {
                side: Side::A,
                skipped: SkippedPath::unrepresentable_name(Some(path("dir")), "a\\b", "has a \\"),
            },
        ],
    );
    assert_eq!(
        text,
        "symlink  A  link  (broken link)\n\
         symlink  B  link  (no follow rule)\n\
         unreadable  A  link  (Permission denied — not synced)\n\
         case-fold  B  link  (folds onto LINK — not synced)\n\
         special  A  link  (fifo)\n\
         unrepresentable  A  dir/a\\b  (has a \\ — not synced)\n"
    );
}

#[test]
fn apply_lines_show_each_action_its_outcome_and_progress() {
    let text = out(
        Verbosity::Normal,
        &[
            RunEvent::Action(copy("f", Side::A)),
            RunEvent::Result {
                action: copy("f", Side::A),
                outcome: Ok(()),
            },
            RunEvent::Result {
                action: copy("g", Side::B),
                outcome: Err(ActionFailure::NoSource { side: Side::B }),
            },
            RunEvent::Result {
                action: copy("h", Side::A),
                outcome: Err(ActionFailure::ChangedDuringSync { side: Side::B }),
            },
            RunEvent::Progress {
                completed: 3,
                total: 3,
            },
        ],
    );
    assert_eq!(
        text,
        "> copy A→B  f\n  applied  copy A→B  f\n  failed   copy B→A  g: replica b has no file to \
         copy at this path\n  failed   copy A→B  h: replica b: changed during sync, left for the \
         next run\n  [3/3]\n"
    );
}

#[test]
fn the_summary_renders_at_every_verbosity_with_unreadable_its_own_count() {
    for verbosity in [Verbosity::Quiet, Verbosity::Normal, Verbosity::Verbose] {
        assert!(
            out(verbosity, &[summary()])
                .contains("summary: applied=1 skipped=2 conflicts=3 failed=4 unreadable=5")
        );
    }
}

#[test]
fn the_size_warning_follows_the_plan_verdict() {
    let view = RunView {
        warn_size_bytes: Some(4),
        ..fixtures::view()
    };
    let warns = |exceeds| {
        rendered(
            &view,
            Verbosity::Normal,
            &[plan_event(vec![copy("f", Side::A)], exceeds)],
        )
        .0
    };
    let over = warns(true);
    assert!(over.starts_with("plan: 1 action(s)"), "{over}");
    assert!(
        over.contains("warning: plan will transfer 5 byte(s), over warn_size_bytes (4) (SPEC §10)")
    );
    assert!(!warns(false).contains("warning"));
    let unset = out(
        Verbosity::Normal,
        &[plan_event(vec![copy("f", Side::A)], true)],
    );
    assert!(!unset.contains("warning"), "no limit, no warning");
}

#[test]
fn the_header_of_a_synced_profile_names_it_both_sides_and_when() {
    let text = out(Verbosity::Normal, &[replicas(Some(120), Some(120), false)]);
    assert_eq!(
        text,
        "profile work\nA  /home/me/notes  local\nB  box:notes  ssh\n  last synced 2023-11-14 \
         22:11 (2 minute(s) ago)\n"
    );
    let apart = out(
        Verbosity::Normal,
        &[replicas(Some(7_200), Some(3 * 86_400), false)],
    );
    assert!(
        apart.contains(
            "last synced A 2023-11-14 20:13 (2 hour(s) ago), B 2023-11-11 22:13 (3 day(s) ago)"
        ),
        "{apart}"
    );
}

#[test]
fn a_unix_side_is_labelled_as_a_socket() {
    let view = RunView {
        b: fixtures::replica("unix:///run/a.sock:/srv/x", Locality::Remote),
        ..fixtures::view()
    };
    let text = rendered(&view, Verbosity::Normal, &[replicas(None, None, false)]).0;
    assert!(
        text.contains("B  unix:///run/a.sock:/srv/x  socket\n"),
        "{text}"
    );
}

#[test]
fn a_first_sync_says_so_and_warns_that_nothing_is_deleted() {
    let text = out(Verbosity::Normal, &[replicas(None, None, false)]);
    assert!(text.contains("  first sync of this pair\n"), "{text}");
    assert!(text.contains("! First sync: with no archive"), "{text}");
    let one_sided = out(Verbosity::Normal, &[replicas(Some(60), None, false)]);
    assert!(
        one_sided.contains("first sync of this pair (B has no archive yet"),
        "{one_sided}"
    );
    assert!(one_sided.contains("! First sync"), "{one_sided}");
}

#[test]
fn an_unfinished_last_run_is_noted_and_a_finished_one_is_not() {
    let unfinished = out(Verbosity::Normal, &[replicas(Some(1), Some(1), true)]);
    assert!(
        unfinished.contains("! The last run of this profile did not finish."),
        "{unfinished}"
    );
    let finished = out(Verbosity::Normal, &[replicas(Some(1), Some(1), false)]);
    assert!(!finished.contains("did not finish"), "{finished}");
}

#[test]
fn an_ad_hoc_run_shows_its_derived_id_instead_of_a_profile_line() {
    let view = RunView {
        name: RunName::AdHoc,
        ..fixtures::view()
    };
    let text = rendered(&view, Verbosity::Normal, &[replicas(None, None, false)]).0;
    assert!(!text.contains("profile "), "{text}");
    assert!(
        text.contains(&format!("  {PROFILE_ID} · first sync of this pair")),
        "{text}"
    );
}

#[test]
fn a_missing_root_names_the_device_it_is_on() {
    let missing = |side| {
        RunEvent::Error(RunError::MissingRoot(MissingReplicaRoot {
            side,
            root_path: "notes".into(),
            archived_files: 3,
        }))
    };
    let (_, remote) = rendered(&fixtures::view(), Verbosity::Normal, &[missing(Side::B)]);
    assert!(
        remote.starts_with("error: The folder notes on box is missing."),
        "{remote}"
    );
    let (_, local) = rendered(&fixtures::view(), Verbosity::Normal, &[missing(Side::A)]);
    assert!(
        local.starts_with("error: The folder notes is missing."),
        "{local}"
    );
}

#[test]
fn an_allowed_mass_delete_is_a_warning_naming_the_replica() {
    let event = |allowed| RunEvent::MassDelete {
        verdict: mass_delete(Side::B, 12, 20),
        allowed,
    };
    assert_eq!(
        out(Verbosity::Normal, &[event(true)]),
        "warning: deleting 12 of the 20 files replica B (box:notes) last synced, as \
         --allow-mass-delete allows (SPEC §10)\n"
    );
    // Not allowed: the prompt or the refusal says it.
    assert_eq!(out(Verbosity::Normal, &[event(false)]), "");
}

#[test]
fn unconfirmed_deletions_are_refused_with_the_way_to_apply_them_even_when_quiet() {
    let refused = RunEvent::Error(RunError::DeletesNotConfirmed(mass_delete(Side::B, 12, 20)));
    let (out, err) = rendered(&fixtures::view(), Verbosity::Quiet, &[refused]);
    assert_eq!(out, "");
    assert_eq!(
        err,
        "error: not applied: this run would delete 12 of the 20 files replica B last synced, \
         and that was not confirmed (SPEC §10). Nothing was changed.\nTo apply it, run \
         interactively and answer y, or rerun with --allow-mass-delete.\n"
    );
}

#[test]
fn a_held_lock_names_the_replica_the_file_and_the_remedy_even_when_quiet() {
    for verbosity in [Verbosity::Quiet, Verbosity::Normal] {
        let (out, err) = rendered(&fixtures::view(), verbosity, &[held_lock()]);
        assert_eq!(out, "");
        assert_eq!(
            err,
            "error: replica A (/home/me/notes) is in use by another dsync process on this \
             machine (lock: /state/a.lock).\nWait for that run to finish, or stop it, then run \
             this again.\n"
        );
    }
}

#[test]
fn a_folder_in_use_names_the_folder_and_says_to_run_again_even_when_quiet() {
    let in_use = RunEvent::Error(RunError::Replica {
        side: Side::B,
        op: ReplicaOp::Lock,
        source: Arc::new(ReplicaError::Lock(LockError::FolderInUse {
            folder: PathBuf::from("/home/me/notes-b"),
            lock: PathBuf::from("/state/folder-0123.lock"),
        })),
    });
    for verbosity in [Verbosity::Quiet, Verbosity::Normal] {
        let (out, err) = rendered(&fixtures::view(), verbosity, std::slice::from_ref(&in_use));
        assert_eq!(out, "");
        assert!(
            err.starts_with("error: replica B (")
                && err.ends_with(
                    "): its folder /home/me/notes-b is in use by another dsync run (lock: \
                     /state/folder-0123.lock).\nRun this again when that run finishes.\n"
                ),
            "{err}"
        );
    }
}

#[test]
fn a_root_in_use_names_its_owner_and_how_to_clear_it_even_when_quiet() {
    let in_use = RunEvent::Error(RunError::Replica {
        side: Side::A,
        op: ReplicaOp::Lock,
        source: Arc::new(ReplicaError::Lock(LockError::RootInUse {
            lock: PathBuf::from("/sdcard/notes/.dsync-lock"),
            owner: "pid 7 on host phone".to_owned(),
        })),
    });
    for verbosity in [Verbosity::Quiet, Verbosity::Normal] {
        let (out, err) = rendered(&fixtures::view(), verbosity, std::slice::from_ref(&in_use));
        assert_eq!(out, "");
        assert!(
            err.starts_with("error: replica A (")
                && err.ends_with(
                    ") is in use by a dsync run of another installation (pid 7 on host phone).\n\
                     Run this again when that run finishes. If it is no longer running, delete \
                     /sdcard/notes/.dsync-lock and run this again.\n"
                ),
            "{err}"
        );
    }
}

#[test]
fn the_scan_tally_shows_only_when_verbose() {
    assert_eq!(out(Verbosity::Quiet, &[scan_tally()]), "");
    assert_eq!(out(Verbosity::Normal, &[scan_tally()]), "");
    assert_eq!(
        out(Verbosity::Verbose, &[scan_tally()]),
        "scan A: 6 path(s) scanned, 2 rehashed to confirm unchanged\nscan B: 0 path(s) \
         scanned, 0 rehashed to confirm unchanged\n"
    );
}

#[test]
fn verbose_shows_everything_normal_does() {
    let events = [
        replicas(None, None, false),
        plan_event(vec![copy("f", Side::A)], false),
        summary(),
    ];
    let normal = out(Verbosity::Normal, &events);
    let verbose = out(Verbosity::Verbose, &events);
    for line in normal.lines() {
        assert!(verbose.contains(line), "verbose lost {line:?}:\n{verbose}");
    }
    assert!(verbose.contains("archive A: /state/x-a.jsonl"), "{verbose}");
}

fn preamble(view: &RunView, verbosity: Verbosity) -> String {
    let (mut out, mut err) = (Vec::new(), Vec::new());
    HumanRenderer::new(&mut out, &mut err, verbosity, view.clone(), clock()).preamble();
    String::from_utf8(out).unwrap()
}

#[test]
fn the_verbose_preamble_shows_rules_locks_and_the_ssh_argv() {
    assert_eq!(
        preamble(&fixtures::view(), Verbosity::Verbose),
        "rules: ignore=[*.tmp] follow=[]\nlock A: /state/a.lock\nssh B: -T box dsync agent \
         --stdio\n"
    );
}

#[test]
fn the_preamble_is_silent_unless_verbose() {
    assert_eq!(preamble(&fixtures::view(), Verbosity::Normal), "");
    assert_eq!(preamble(&fixtures::view(), Verbosity::Quiet), "");
}

#[test]
fn a_dialled_peer_s_certificate_notes_sit_under_its_side() {
    use dsync_core::PeerContact;
    use dsync_domain::host_port::PeerAddress;
    use dsync_domain::{
        CertificateExpiry, CertificateOwner, CertificateValidity, DeviceId, PeerName,
    };

    let now = std::time::SystemTime::now();
    let ending = CertificateValidity::new(now, now + Duration::from_secs(5 * 86_400));
    let expiry = |owner| {
        ending
            .expiry_within(owner, now, CertificateExpiry::DEFAULT_WINDOW)
            .unwrap()
    };
    let peer = PeerContact {
        side: Side::B,
        device: DeviceId::from_spki_der(b"spki"),
        address: PeerAddress::new("192.168.1.5", 28771).unwrap(),
        expiries: vec![
            expiry(CertificateOwner::ThisHost),
            expiry(CertificateOwner::Peer(PeerName::parse("phone").unwrap())),
        ],
    };
    let view = fixtures::view();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let mut renderer =
        HumanRenderer::new(&mut out, &mut err, Verbosity::Normal, view.clone(), clock());
    renderer.peer_contacts(&[peer]);
    renderer.render(&replicas(Some(120), Some(120), false));
    let text = String::from_utf8(out).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[2], "B  box:notes  ssh", "{text}");
    assert!(
        lines[3].starts_with("   certificate for this host expires in"),
        "{text}"
    );
    assert!(
        lines[4].starts_with("   certificate for phone expires in"),
        "{text}"
    );
    // Positive control: without notes, the header goes straight on.
    assert!(!out_of_header().contains("certificate"));
}

fn out_of_header() -> String {
    out(Verbosity::Normal, &[replicas(Some(120), Some(120), false)])
}

#[test]
fn entering_an_entry_headers_it_only_when_there_is_more_than_one() {
    let one = {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut renderer = HumanRenderer::new(
            &mut out,
            &mut err,
            Verbosity::Normal,
            fixtures::view(),
            clock(),
        );
        renderer.enter_entry(0, 1, fixtures::view());
        String::from_utf8(out).unwrap()
    };
    assert_eq!(one, "", "a single entry gets no heading");

    let many = {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut renderer = HumanRenderer::new(
            &mut out,
            &mut err,
            Verbosity::Normal,
            fixtures::view(),
            clock(),
        );
        renderer.enter_entry(1, 3, fixtures::view());
        String::from_utf8(out).unwrap()
    };
    assert_eq!(many, "[2/3] /home/me/notes ↔ box:notes\n");
}

#[test]
fn a_connect_failure_is_reported_as_the_entry_s_only_word() {
    use dsync_core::{ConnectError, ConnectFailure};

    let (mut out, mut err) = (Vec::new(), Vec::new());
    let mut renderer = HumanRenderer::new(
        &mut out,
        &mut err,
        Verbosity::Normal,
        fixtures::view(),
        clock(),
    );
    renderer.connect_failed(&ConnectError {
        side: Side::A,
        failure: ConnectFailure::NoIdentity,
    });
    assert_eq!(String::from_utf8(out).unwrap(), "");
    let err = String::from_utf8(err).unwrap();
    assert!(
        err.starts_with("error: Cannot reach replica A: peer:// locations need"),
        "{err}"
    );
}

#[test]
fn a_redial_is_one_stderr_line_naming_the_device_and_the_attempt() {
    use dsync_core::{LinkError, ReconnectCause, ReplicaError, RunError};
    use dsync_domain::ReplicaOp;

    let (mut out, mut err) = (Vec::new(), Vec::new());
    let mut renderer = HumanRenderer::new(
        &mut out,
        &mut err,
        Verbosity::Normal,
        fixtures::view(),
        clock(),
    );
    renderer.reconnecting(
        2,
        &ReconnectCause::Run(RunError::Replica {
            side: Side::B,
            op: ReplicaOp::Scan,
            source: std::sync::Arc::new(ReplicaError::Link(LinkError::Closed)),
        }),
    );
    assert_eq!(String::from_utf8(out).unwrap(), "");
    assert_eq!(
        String::from_utf8(err).unwrap(),
        "connection to box lost; reconnecting (2)\n"
    );
}

#[test]
fn the_closing_list_is_silent_for_one_entry_and_names_each_outcome_for_several() {
    use dsync_core::{EntryFailure, EntryOutcome, EntryReport, SkipReason};

    let report = |outcome| EntryReport {
        outcome,
        metrics: None,
        planned: 0,
        finished: 0,
        reconnects: 0,
    };
    let synced = report(EntryOutcome::Synced(RunSummary::default()));
    let skipped = report(EntryOutcome::Skipped(SkipReason::Missing(
        MissingReplicaRoot {
            side: Side::B,
            root_path: "photos".into(),
            archived_files: 4,
        },
    )));
    let not_run = report(EntryOutcome::NotRun);
    let failed = report(EntryOutcome::Failed(EntryFailure::Dropped));

    let one_entry = {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut renderer = HumanRenderer::new(
            &mut out,
            &mut err,
            Verbosity::Normal,
            fixtures::view(),
            clock(),
        );
        renderer.entry_outcomes(&[fixtures::view()], std::slice::from_ref(&synced));
        String::from_utf8(out).unwrap()
    };
    assert_eq!(one_entry, "", "a single entry gets no closing list");

    let views = [
        fixtures::view(),
        fixtures::view(),
        fixtures::view(),
        fixtures::view(),
    ];
    let entries = [synced, skipped, failed, not_run];
    let many_entries = {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut renderer = HumanRenderer::new(
            &mut out,
            &mut err,
            Verbosity::Normal,
            fixtures::view(),
            clock(),
        );
        renderer.entry_outcomes(&views, &entries);
        String::from_utf8(out).unwrap()
    };
    assert!(many_entries.starts_with("entries:\n"), "{many_entries}");
    assert!(
        many_entries.contains("[1/4]") && many_entries.contains("synced"),
        "{many_entries}"
    );
    assert!(
        many_entries.contains("[2/4]") && many_entries.contains("skipped: The folder photos"),
        "{many_entries}"
    );
    assert!(
        many_entries.contains("[3/4]") && many_entries.contains("failed: dropped"),
        "{many_entries}"
    );
    assert!(
        many_entries.contains("[4/4]") && many_entries.contains("not run"),
        "{many_entries}"
    );
}
