use std::sync::Arc;
use std::time::{Duration, SystemTime};

use dsync_core::{ActionFailure, ReplicaError, RunError, RunEvent};
use dsync_domain::{
    Action, Locality, Plan, ReplicaInfo, ReplicaOp, ReplicaRoot, RunSummary, ScanTally, Side,
    SkippedPath, SkippedReason, Status, Unchanged,
};
use serde_json::{Value, json};

use super::JsonRenderer;
use crate::render::RunView;
use crate::render::fixtures::{self, PROFILE_ID, conflict, created, path, proposed, unchanged};

fn lines(view: &RunView, events: &[RunEvent]) -> Vec<Value> {
    let mut out = Vec::new();
    let mut renderer = JsonRenderer::new(&mut out, view);
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
        last_run_unfinished: false,
    });
    assert_eq!(
        line,
        json!({
            "type": "replicas",
            "profileId": PROFILE_ID,
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
            "lastRunUnfinished": false,
        })
    );
}

#[test]
fn a_first_sync_and_an_unfinished_run_are_facts_on_the_replicas_line() {
    let line = one(RunEvent::Replicas {
        a: info(None, None),
        b: info(Some(SystemTime::UNIX_EPOCH), None),
        last_run_unfinished: true,
    });
    assert_eq!(line["firstSync"], true);
    assert_eq!(line["lastRunUnfinished"], true);
    assert!(line["a"].get("lastCommitTime").is_none());
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
            last_run_unfinished: false,
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
        json!({"metadataMatched": 3, "hashMatched": 2, "modified": 0, "created": 0, "deleted": 0, "untrusted": 0})
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
            json!({"type": kind, "path": "x", "onA": false, "detail": "why"})
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
            "path": "c",
            "onA": "unchanged",
            "onAReason": "hashMatched",
            "onB": "modified",
            "onBReason": "modified",
        })
    );
}

#[test]
fn a_conflict_over_an_uncommitted_write_is_interrupted_and_an_absent_side_omits_its_keys() {
    let line = one(RunEvent::Conflict(conflict(
        "c",
        None,
        Some(Status::Untrusted(fixtures::file(2))),
    )));
    assert_eq!(line["interrupted"], true);
    assert!(line.get("onA").is_none() && line.get("onAReason").is_none());
    assert_eq!(line["onB"], "untrusted");
}

#[test]
fn action_progress_result_summary_and_error_lines() {
    assert_eq!(
        one(RunEvent::Action(copy("f"))),
        json!({"type": "action", "path": "f", "actionType": "copyAtoB", "bytes": 5})
    );
    assert_eq!(
        one(RunEvent::Progress {
            completed: 1,
            total: 3
        }),
        json!({"type": "progress", "completed": 1, "total": 3})
    );
    assert_eq!(
        one(RunEvent::Result {
            action: Action::Delete {
                path: path("d"),
                on: Side::B
            },
            outcome: Ok(()),
        }),
        json!({"type": "result", "path": "d", "actionType": "deleteOnB", "succeeded": true})
    );
    assert_eq!(
        one(RunEvent::Result {
            action: copy("f"),
            outcome: Err(ActionFailure::NoSource { side: Side::A }),
        }),
        json!({
            "type": "result",
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
            "message": "replica a: hello failed: no scan exchange is open at that phase on this replica",
        })
    );
}

#[test]
fn a_whole_run_is_one_decodable_line_per_event_in_order() {
    let events = [
        RunEvent::Replicas {
            a: info(None, None),
            b: info(None, None),
            last_run_unfinished: false,
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
