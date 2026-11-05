use std::sync::Arc;
use std::time::{Duration, SystemTime};

use dsync_core::{ActionFailure, LastRun, ReplicaError, RunError, RunEvent};
use dsync_domain::{
    Action, Locality, Plan, ReplicaInfo, ReplicaOp, ReplicaRoot, RunSummary, ScanTally, Side,
    SkippedPath, SkippedReason, Status, Unchanged,
};
use serde_json::{Value, json};

use super::JsonRenderer;
use crate::render::RunView;
use crate::render::fixtures::{
    self, PROFILE_ID, conflict, created, mass_delete, mass_overwrite, path, proposed, unchanged,
};

fn lines(view: &RunView, events: &[RunEvent]) -> Vec<Value> {
    let mut out = Vec::new();
    let mut renderer = JsonRenderer::new(&mut out, view.clone());
    for event in events {
        renderer.render(event);
    }
    String::from_utf8(out)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).expect("every line is one JSON object"))
        .collect()
}

fn one(event: RunEvent) -> Value {
    let mut all = lines(&fixtures::view(), &[event]);
    assert_eq!(all.len(), 1);
    all.remove(0)
}

fn copy(at: &str) -> Action {
    Action::Copy {
        path: path(at),
        from: Side::A,
        bytes: 5,
    }
}

fn info(last_commit: Option<SystemTime>, archive: Option<&str>) -> ReplicaInfo {
    ReplicaInfo {
        last_commit,
        archived_files: 0,
        archive_path: archive.map(str::to_owned),
        root: ReplicaRoot::Present,
    }
}

#[test]
fn replicas_carry_each_side_location_locality_archive_and_last_commit() {
    let at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
    let line = one(RunEvent::Replicas {
        a: info(Some(at), Some("/state/x-a.jsonl")),
        b: info(Some(at), None),
        last_run: LastRun::Settled,
    });
    assert_eq!(
        line,
        json!({
            "type": "replicas",
            "entry": 0,
            "entryId": PROFILE_ID,
            "a": {
                "location": {"path": "/home/me/notes"},
                "locality": "inProcess",
                "archivePath": "/state/x-a.jsonl",
                "lastCommitTime": "2023-11-14T22:13:20Z",
            },
            "b": {
                "location": {"path": "notes", "host": "box"},
                "locality": "remote",
                "lastCommitTime": "2023-11-14T22:13:20Z",
            },
            "firstSync": false,
            "lastRun": "settled",
        })
    );
}

#[test]
fn a_first_sync_and_an_unfinished_run_are_facts_on_the_replicas_line() {
    let line = one(RunEvent::Replicas {
        a: info(None, None),
        b: info(Some(SystemTime::UNIX_EPOCH), None),
        last_run: LastRun::Died,
    });
    assert_eq!(line["firstSync"], true);
    assert_eq!(line["lastRun"], "died");
    assert!(line["a"].get("lastCommitTime").is_none());
}

#[test]
fn a_write_still_held_after_a_finished_run_is_its_own_last_run() {
    let line = one(RunEvent::Replicas {
        a: info(None, None),
        b: info(None, None),
        last_run: LastRun::WriteHeld,
    });
    assert_eq!(line["lastRun"], "writeHeld");
}

#[test]
fn a_unix_side_reports_a_socket_never_a_host() {
    let view = RunView {
        b: fixtures::replica("unix:///run/a.sock:/srv/x", Locality::Remote),
        ..fixtures::view()
    };
    let line = lines(
        &view,
        &[RunEvent::Replicas {
            a: info(None, None),
            b: info(None, None),
            last_run: LastRun::Settled,
        }],
    )
    .remove(0);
    assert_eq!(
        line["b"]["location"],
        json!({"path": "/srv/x", "socket": "/run/a.sock"})
    );
}

#[test]
fn plan_actions_and_conflicts_are_shaped_like_their_own_lines() {
    let line = one(RunEvent::Plan {
        plan: Plan {
            actions: proposed(vec![copy("f")]),
            conflicts: vec![conflict("c", Some(created(1)), None)],
        },
        exceeds_warn_size: false,
    });
    assert_eq!(
        line,
        json!({
            "type": "plan",
            "entry": 0,
            "actions": [{"path": "f", "actionType": "copyAtoB", "bytes": 5}],
            "conflicts": [{"path": "c", "onA": "created", "onAReason": "created"}],
        })
    );
}

#[test]
fn scan_tally_counts_both_sides_by_branch() {
    let line = one(RunEvent::ScanTally {
        a: ScanTally {
            metadata_matched: 3,
            hash_matched: 2,
            ..ScanTally::default()
        },
        b: ScanTally::default(),
    });
    assert_eq!(
        line["a"],
        json!({"metadataMatched": 3, "hashMatched": 2, "modified": 0, "created": 0, "deleted": 0})
    );
    assert_eq!(line["b"]["metadataMatched"], 0);
}

#[test]
fn each_skipped_reason_is_its_own_type() {
    for (reason, kind) in [
        (SkippedReason::Symlink, "symlink"),
        (SkippedReason::Unreadable, "unreadable"),
        (SkippedReason::CaseFoldCollision, "caseFoldCollision"),
        (SkippedReason::SpecialFile, "specialFile"),
    ] {
        let line = one(RunEvent::Skipped {
            side: Side::B,
            skipped: SkippedPath::new(path("x"), reason, "why"),
        });
        assert_eq!(
            line,
            json!({"type": kind, "entry": 0, "path": "x", "onA": false, "detail": "why"})
        );
    }
    let line = one(RunEvent::Skipped {
        side: Side::A,
        skipped: SkippedPath::unrepresentable_name(None, "a\\b", "has a \\"),
    });
    assert_eq!(line["type"], "unrepresentableName");
    assert_eq!(line["path"], "a\\b");
    assert_eq!(line["onA"], true);
}

#[test]
fn a_conflict_carries_each_side_status_and_reason() {
    let line = one(RunEvent::Conflict(conflict(
        "c",
        Some(unchanged(Unchanged::HashMatched)),
        Some(Status::Modified(fixtures::file(2))),
    )));
    assert_eq!(
        line,
        json!({
            "type": "conflict",
            "entry": 0,
            "path": "c",
            "onA": "unchanged",
            "onAReason": "hashMatched",
            "onB": "modified",
            "onBReason": "modified",
        })
    );
}

#[test]
fn an_absent_side_of_a_conflict_omits_its_keys() {
    let line = one(RunEvent::Conflict(conflict(
        "c",
        None,
        Some(Status::Modified(fixtures::file(2))),
    )));
    assert!(line.get("onA").is_none() && line.get("onAReason").is_none());
    assert_eq!(line["onB"], "modified");
}

#[test]
fn a_conflict_held_back_after_an_unfinished_apply_names_the_side_written() {
    let plain = conflict("c", Some(unchanged(Unchanged::MetadataMatched)), None);
    assert!(
        one(RunEvent::Conflict(plain.clone()))
            .get("unfinishedWriteOn")
            .is_none()
    );
    let held = dsync_domain::Conflict {
        cause: dsync_domain::ConflictCause::UnfinishedWrite(dsync_domain::Side::B),
        ..plain
    };
    assert_eq!(one(RunEvent::Conflict(held))["unfinishedWriteOn"], "B");
}

#[test]
fn action_progress_result_summary_and_error_lines() {
    assert_eq!(
        one(RunEvent::Action(copy("f"))),
        json!({"type": "action", "entry": 0, "path": "f", "actionType": "copyAtoB", "bytes": 5})
    );
    assert_eq!(
        one(RunEvent::Progress {
            completed: 1,
            received: 2,
            total: 3
        }),
        json!({"type": "progress", "entry": 0, "completed": 1, "received": 2, "total": 3})
    );
    assert_eq!(
        one(RunEvent::Result {
            action: Action::Delete {
                path: path("d"),
                on: Side::B
            },
            outcome: Ok(()),
        }),
        json!({
            "type": "result",
            "entry": 0,
            "path": "d",
            "actionType": "deleteOnB",
            "succeeded": true,
        })
    );
    assert_eq!(
        one(RunEvent::Result {
            action: copy("f"),
            outcome: Err(ActionFailure::NoSource { side: Side::A }),
        }),
        json!({
            "type": "result",
            "entry": 0,
            "path": "f",
            "actionType": "copyAtoB",
            "succeeded": false,
            "error": "replica a has no file to copy at this path",
        })
    );
    assert_eq!(
        one(RunEvent::Result {
            action: copy("f"),
            outcome: Err(ActionFailure::ChangedDuringSync { side: Side::B }),
        }),
        json!({
            "type": "result",
            "entry": 0,
            "path": "f",
            "actionType": "copyAtoB",
            "succeeded": false,
            "error": "replica b: changed during sync, left for the next run",
        })
    );
    assert_eq!(
        one(RunEvent::Summary(RunSummary {
            applied: 1,
            skipped: 2,
            conflicts: 3,
            failed: 4,
            unreadable: 5,
        })),
        json!({
            "type": "summary",
            "entry": 0,
            "appliedCount": 1,
            "failedCount": 4,
            "conflictCount": 3,
            "skippedCount": 2,
            "unreadableCount": 5,
        })
    );
    assert_eq!(
        one(RunEvent::Error(RunError::Replica {
            side: Side::A,
            op: ReplicaOp::Hello,
            source: Arc::new(ReplicaError::NoScan),
        })),
        json!({
            "type": "error",
            "entry": 0,
            "message": "replica a: hello failed: no scan exchange is open at that phase on this replica",
        })
    );
}

#[test]
fn a_mass_delete_reports_each_side_count_share_and_sample() {
    let line = one(RunEvent::MassDelete {
        verdict: mass_delete(Side::A, 11, 11),
        allowed: false,
    });
    assert_eq!(
        line,
        json!({
            "type": "massDelete",
            "entry": 0,
            "allowed": false,
            "a": {
                "deletes": 11,
                "archived": 11,
                "paths": ["f00", "f01", "f02", "f03", "f04"],
            },
            "b": null,
        })
    );
    let refused = one(RunEvent::Error(RunError::DeletesNotConfirmed(mass_delete(
        Side::A,
        11,
        11,
    ))));
    assert_eq!(refused["type"], "error");
    assert!(
        refused["message"]
            .as_str()
            .is_some_and(|message| message.starts_with("not applied: this run would delete 11")),
        "{refused}"
    );
}

#[test]
fn a_mass_overwrite_reports_each_side_count_emptied_share_and_sample() {
    let line = one(RunEvent::MassOverwrite {
        verdict: mass_overwrite(Side::B, 12, 1, 12),
        allowed: true,
    });
    assert_eq!(
        line,
        json!({
            "type": "massOverwrite",
            "entry": 0,
            "allowed": true,
            "a": null,
            "b": {
                "overwrites": 12,
                "truncated": 1,
                "archived": 12,
                "paths": ["f11", "f00", "f01", "f02", "f03"],
            },
        })
    );
    let refused = one(RunEvent::Error(RunError::OverwritesNotConfirmed(
        mass_overwrite(Side::B, 12, 0, 12),
    )));
    assert_eq!(refused["type"], "error");
    assert!(
        refused["message"]
            .as_str()
            .is_some_and(|message| message.starts_with("not applied: this run would overwrite 12")),
        "{refused}"
    );
}

#[test]
fn a_whole_run_is_one_decodable_line_per_event_in_order() {
    let events = [
        RunEvent::Replicas {
            a: info(None, None),
            b: info(None, None),
            last_run: LastRun::Settled,
        },
        RunEvent::ScanTally {
            a: ScanTally::default(),
            b: ScanTally::default(),
        },
        RunEvent::Plan {
            plan: Plan::default(),
            exceeds_warn_size: false,
        },
        RunEvent::Summary(RunSummary::default()),
    ];
    let kinds: Vec<_> = lines(&fixtures::view(), &events)
        .iter()
        .map(|line| line["type"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(kinds, ["replicas", "scanTally", "plan", "summary"]);
}

#[test]
fn entries_are_listed_by_index_kind_and_typed_sides() {
    use dsync_core::ListedEntry;
    use dsync_domain::{EntryId, RootKind};

    let list = vec![
        ListedEntry {
            entry_id: EntryId::parse(PROFILE_ID).unwrap(),
            kind: RootKind::Folder,
            a: "~/notes".to_owned(),
            b: "peer://phone/notes".to_owned(),
        },
        ListedEntry {
            entry_id: EntryId::parse("fedcba9876543210fedcba9876543210").unwrap(),
            kind: RootKind::File,
            a: "~/notes.md".to_owned(),
            b: "peer://phone/notes.md".to_owned(),
        },
    ];
    let mut out = Vec::new();
    let mut renderer = JsonRenderer::new(&mut out, fixtures::view());
    renderer.entries_listed(&list);
    let line: Value = serde_json::from_str(std::str::from_utf8(&out).unwrap().trim()).unwrap();
    assert_eq!(
        line,
        json!({
            "type": "entries",
            "version": "1.1",
            "entries": [
                {"index": 0, "entryId": PROFILE_ID, "kind": "folder", "a": "~/notes", "b": "peer://phone/notes"},
                {"index": 1, "entryId": "fedcba9876543210fedcba9876543210", "kind": "file", "a": "~/notes.md", "b": "peer://phone/notes.md"},
            ],
        })
    );
}

#[test]
fn entering_an_entry_moves_every_later_event_s_entry_field() {
    let mut out = Vec::new();
    let mut renderer = JsonRenderer::new(&mut out, fixtures::view());
    renderer.enter_entry(2, fixtures::view());
    renderer.render(&RunEvent::Summary(RunSummary::default()));
    let line: Value = serde_json::from_str(std::str::from_utf8(&out).unwrap().trim()).unwrap();
    assert_eq!(line["entry"], 2);
}

#[test]
fn a_connect_failure_is_an_error_line_naming_its_entry() {
    use dsync_core::{ConnectError, ConnectFailure};

    let mut out = Vec::new();
    let mut renderer = JsonRenderer::new(&mut out, fixtures::view());
    renderer.enter_entry(1, fixtures::view());
    renderer.connect_failed(&ConnectError {
        side: Side::B,
        failure: ConnectFailure::NoIdentity,
    });
    let line: Value = serde_json::from_str(std::str::from_utf8(&out).unwrap().trim()).unwrap();
    assert_eq!(line["type"], "error");
    assert_eq!(line["entry"], 1);
    assert!(
        line["message"]
            .as_str()
            .is_some_and(|message| message.contains("peer:// locations need")),
        "{line}"
    );
}

#[test]
fn a_redial_is_a_reconnecting_line_with_its_attempt_wait_and_cause() {
    use dsync_core::{LinkError, ReconnectCause};

    let mut out = Vec::new();
    let mut renderer = JsonRenderer::new(&mut out, fixtures::view());
    renderer.enter_entry(1, fixtures::view());
    renderer.reconnecting(
        3,
        Duration::from_millis(4000),
        &ReconnectCause::Run(RunError::Replica {
            side: Side::B,
            op: ReplicaOp::Scan,
            source: Arc::new(ReplicaError::Link(LinkError::Closed)),
        }),
    );
    let line: Value = serde_json::from_str(std::str::from_utf8(&out).unwrap().trim()).unwrap();
    assert_eq!(
        line,
        json!({
            "type": "reconnecting",
            "entry": 1,
            "attempt": 3,
            "afterMs": 4000,
            "message": "replica b: scan failed: the connection to the replica closed",
        })
    );
}
