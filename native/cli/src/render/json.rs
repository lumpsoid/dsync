//! `--json` (SPEC §11.4): one object per event on stdout, each with a
//! `type`: `replicas`, `scanTally`, `symlink` / `unreadable` /
//! `caseFoldCollision` / `unrepresentableName`, `conflict`, `plan`,
//! `action`, `result`, `progress`, `summary`, `error`. Facts only; the
//! human warnings are renderings of them.

use std::io::Write;

use dsync_core::RunEvent;
use dsync_domain::{Action, Conflict, Location, ReplicaInfo, ScanTally, Side, Status};
use serde_json::{Map, Value, json};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use super::{RunView, words};

pub struct JsonRenderer<'v, O: Write> {
    out: O,
    view: &'v RunView,
}

impl<'v, O: Write> JsonRenderer<'v, O> {
    pub fn new(out: O, view: &'v RunView) -> JsonRenderer<'v, O> {
        JsonRenderer { out, view }
    }

    pub fn render(&mut self, event: &RunEvent) {
        let line = self.line(event);
        let _ = writeln!(self.out, "{line}");
    }

    fn line(&self, event: &RunEvent) -> Value {
        match event {
            RunEvent::Replicas {
                a,
                b,
                last_run_unfinished,
            } => json!({
                "type": "replicas",
                "profileId": self.view.profile_id.as_str(),
                "a": self.replica(Side::A, a),
                "b": self.replica(Side::B, b),
                "firstSync": a.last_commit.is_none() || b.last_commit.is_none(),
                "lastRunUnfinished": last_run_unfinished,
            }),
            RunEvent::ScanTally { a, b } => json!({
                "type": "scanTally",
                "a": tally(a),
                "b": tally(b),
            }),
            RunEvent::Skipped { side, skipped } => json!({
                "type": words::skipped_type(skipped.reason),
                "path": words::skipped_at(&skipped.at),
                "onA": *side == Side::A,
                "detail": skipped.detail,
            }),
            RunEvent::Conflict(conflict) => typed("conflict", conflict_fields(conflict)),
            RunEvent::Plan { plan, .. } => json!({
                "type": "plan",
                "actions": plan.actions.iter().map(|a| Value::Object(action_fields(a))).collect::<Vec<_>>(),
                "conflicts": plan.conflicts.iter().map(|c| Value::Object(conflict_fields(c))).collect::<Vec<_>>(),
            }),
            RunEvent::Action(action) => typed("action", action_fields(action)),
            RunEvent::Result { action, outcome } => {
                let mut fields = Map::new();
                fields.insert("path".into(), json!(action.path().as_str()));
                fields.insert("actionType".into(), json!(words::action_type(action)));
                fields.insert("succeeded".into(), json!(outcome.is_ok()));
                if let Err(failure) = outcome {
                    fields.insert("error".into(), json!(failure.to_string()));
                }
                typed("result", fields)
            }
            RunEvent::Progress { completed, total } => json!({
                "type": "progress",
                "completed": completed,
                "total": total,
            }),
            RunEvent::Summary(summary) => json!({
                "type": "summary",
                "appliedCount": summary.applied,
                "failedCount": summary.failed,
                "conflictCount": summary.conflicts,
                "skippedCount": summary.skipped,
                "unreadableCount": summary.unreadable,
            }),
            RunEvent::Error(error) => json!({
                "type": "error",
                "message": error.to_string(),
            }),
        }
    }

    fn replica(&self, side: Side, info: &ReplicaInfo) -> Value {
        let replica = self.view.replica(side);
        let mut fields = Map::new();
        fields.insert("location".into(), location(&replica.location.to_location()));
        fields.insert(
            "locality".into(),
            json!(match replica.locality {
                dsync_domain::Locality::InProcess => "inProcess",
                dsync_domain::Locality::Remote => "remote",
            }),
        );
        if let Some(archive) = &info.archive_path {
            fields.insert("archivePath".into(), json!(archive));
        }
        if let Some(at) = info.last_commit
            && let Ok(text) = OffsetDateTime::from(at).format(&Rfc3339)
        {
            fields.insert("lastCommitTime".into(), json!(text));
        }
        Value::Object(fields)
    }
}

fn typed(kind: &str, fields: Map<String, Value>) -> Value {
    let mut line = Map::new();
    line.insert("type".into(), json!(kind));
    line.extend(fields);
    Value::Object(line)
}

fn action_fields(action: &Action) -> Map<String, Value> {
    let mut fields = Map::new();
    fields.insert("path".into(), json!(action.path().as_str()));
    fields.insert("actionType".into(), json!(words::action_type(action)));
    fields.insert("bytes".into(), json!(action.bytes()));
    fields
}

/// A side with no record of the path omits its keys rather than carrying
/// nulls.
fn conflict_fields(conflict: &Conflict) -> Map<String, Value> {
    let mut fields = Map::new();
    fields.insert("path".into(), json!(conflict.path.as_str()));
    let mut side = |key: &str, status: Option<&Status>| {
        if let Some(status) = status {
            fields.insert(key.into(), json!(words::status(status)));
            fields.insert(format!("{key}Reason"), json!(words::reason(status)));
        }
    };
    side("onA", conflict.a.as_ref());
    side("onB", conflict.b.as_ref());
    if conflict.interrupted() {
        fields.insert("interrupted".into(), json!(true));
    }
    fields
}

fn tally(tally: &ScanTally) -> Value {
    json!({
        "metadataMatched": tally.metadata_matched,
        "hashMatched": tally.hash_matched,
        "modified": tally.modified,
        "created": tally.created,
        "deleted": tally.deleted,
        "untrusted": tally.untrusted,
    })
}

fn location(location: &Location) -> Value {
    match location {
        Location::Local(local) => json!({ "path": local.path() }),
        Location::Ssh(ssh) => {
            let mut fields = Map::new();
            fields.insert("path".into(), json!(ssh.path()));
            fields.insert("host".into(), json!(ssh.host()));
            if let Some(user) = ssh.user() {
                fields.insert("user".into(), json!(user));
            }
            Value::Object(fields)
        }
        Location::Unix(unix) => json!({ "path": unix.path(), "socket": unix.socket() }),
        Location::Peer(peer) => json!({ "path": peer.path(), "peer": peer.device().as_str() }),
    }
}

#[cfg(test)]
mod tests;
