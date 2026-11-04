//! `--json` (SPEC §11.4): one object per event on stdout, each with a
//! `type`: `replicas`, `scanTally`, `symlink` / `unreadable` /
//! `caseFoldCollision` / `unrepresentableName`, `conflict`, `plan`,
//! `massDelete`, `action`, `result`, `progress`, `summary`, `error`; and
//! around them `entries` and `reconnecting`. Facts only; the human warnings
//! are renderings of them.

use std::io::Write;
use std::time::Duration;

use dsync_core::{ConnectError, ListedEntry, ReconnectCause, RunEvent};
use dsync_domain::{
    Action, Conflict, ConflictCause, FormatVersion, Location, MassDelete, MassOverwrite,
    ReplicaInfo, ScanTally, Side, Status,
};
use serde_json::{Map, Value, json};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use super::{RunView, words};

/// This output's format, on its leading `entries` line (SPEC §11.4). The
/// major moves when a consumer would otherwise read a line wrong - a field
/// or `type` renamed, removed or given another meaning; the minor when a
/// field or `type` is added, which a consumer ignores.
const JSON_FORMAT_VERSION: FormatVersion = FormatVersion::new(1, 0);

pub struct JsonRenderer<O: Write> {
    out: O,
    view: RunView,
    /// The entry the events rendered from here on belong to, set by
    /// [`JsonRenderer::enter_entry`]; `0` before the first.
    entry: usize,
}

impl<O: Write> JsonRenderer<O> {
    pub fn new(out: O, view: RunView) -> JsonRenderer<O> {
        JsonRenderer {
            out,
            view,
            entry: 0,
        }
    }

    /// The profile's entries, before the first connects: `[{index,
    /// entryId, kind, a, b}]`, in run order, under the output's
    /// [`JSON_FORMAT_VERSION`].
    pub fn entries_listed(&mut self, list: &[ListedEntry]) {
        let entries: Vec<Value> = list
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                json!({
                    "index": index,
                    "entryId": entry.entry_id.as_str(),
                    "kind": entry.kind.key(),
                    "a": entry.a,
                    "b": entry.b,
                })
            })
            .collect();
        let line = json!({
            "type": "entries",
            "version": JSON_FORMAT_VERSION.to_string(),
            "entries": entries,
        });
        let _ = writeln!(self.out, "{line}");
    }

    /// Moves on to entry `index`: every event from here on carries it.
    pub fn enter_entry(&mut self, index: usize, view: RunView) {
        self.entry = index;
        self.view = view;
    }

    /// An entry's side could not be connected: its run never started, so
    /// this is the only line of it.
    pub fn connect_failed(&mut self, error: &ConnectError) {
        let line = json!({"type": "error", "entry": self.entry, "message": error.to_string()});
        let _ = writeln!(self.out, "{line}");
    }

    /// A dropped link is dialled again `after` from now: supersedes the
    /// `error` line the dropped attempt's run wrote before it, which is
    /// not the entry's end.
    pub fn reconnecting(&mut self, attempt: u32, after: Duration, cause: &ReconnectCause) {
        let line = json!({
            "type": "reconnecting",
            "entry": self.entry,
            "attempt": attempt,
            "afterMs": u64::try_from(after.as_millis()).unwrap_or(u64::MAX),
            "message": cause.to_string(),
        });
        let _ = writeln!(self.out, "{line}");
    }

    pub fn render(&mut self, event: &RunEvent) {
        let mut line = self.line(event);
        if let Value::Object(fields) = &mut line {
            fields.insert("entry".into(), json!(self.entry));
        }
        let _ = writeln!(self.out, "{line}");
    }

    fn line(&self, event: &RunEvent) -> Value {
        match event {
            RunEvent::Replicas { a, b, last_run } => json!({
                "type": "replicas",
                "entryId": self.view.entry_id.as_str(),
                "a": self.replica(Side::A, a),
                "b": self.replica(Side::B, b),
                "firstSync": a.last_commit.is_none() || b.last_commit.is_none(),
                "lastRun": words::last_run(*last_run),
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
                "actions": plan.actions.iter().map(|p| Value::Object(action_fields(&p.action))).collect::<Vec<_>>(),
                "conflicts": plan.conflicts.iter().map(|c| Value::Object(conflict_fields(c))).collect::<Vec<_>>(),
            }),
            RunEvent::MassDelete { verdict, allowed } => json!({
                "type": "massDelete",
                "allowed": allowed,
                "a": side_deletes(verdict, Side::A),
                "b": side_deletes(verdict, Side::B),
            }),
            RunEvent::MassOverwrite { verdict, allowed } => json!({
                "type": "massOverwrite",
                "allowed": allowed,
                "a": side_overwrites(verdict, Side::A),
                "b": side_overwrites(verdict, Side::B),
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

/// One side's share of SPEC §10's verdict, `null` when that side did not
/// trip it.
fn side_deletes(verdict: &MassDelete, side: Side) -> Value {
    verdict.side(side).map_or(Value::Null, |deletes| {
        json!({
            "deletes": deletes.deletes,
            "archived": deletes.archived,
            "paths": deletes.sample.iter().map(|path| path.as_str()).collect::<Vec<_>>(),
        })
    })
}

/// One side's share of SPEC §10's overwrite verdict, `null` when that side
/// did not trip it.
fn side_overwrites(verdict: &MassOverwrite, side: Side) -> Value {
    verdict.side(side).map_or(Value::Null, |overwrites| {
        json!({
            "overwrites": overwrites.overwrites,
            "truncated": overwrites.truncated,
            "archived": overwrites.archived,
            "paths": overwrites.sample.iter().map(|path| path.as_str()).collect::<Vec<_>>(),
        })
    })
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
/// nulls; `unfinishedWriteOn` names the side a dead apply was writing the
/// path on (SPEC §7.6), and only a conflict held back for that has it.
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
    if let ConflictCause::UnfinishedWrite(on) = conflict.cause {
        fields.insert("unfinishedWriteOn".into(), json!(words::side(on)));
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
