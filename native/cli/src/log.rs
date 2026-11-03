//! `dsync log` (SPEC §11.1): the run history in this host's state
//! directory, oldest run first - when each ran, how each entry ended, and
//! every path it deleted, overwrote or failed on.

use std::io::{self, Write};
use std::time::{Duration, SystemTime};

use dsync_core::{RunHistory, StateDir};
use dsync_domain::{EntryRecord, Mode, RecordedOutcome, RunRecord, SidePath};
use serde_json::{Value, json};

use crate::args::ListArgs;
use crate::failure::Failure;
use crate::host::Host;
use crate::render::rfc3339;

/// Runs `dsync log`, returning its exit code.
pub fn log(args: &ListArgs, host: &Host) -> Result<u8, Failure> {
    let state = StateDir::resolve(&args.state.choice()?, &host.facts).map_err(Failure::error)?;
    let records = RunHistory::new(&state)
        .read()
        .map_err(|error| Failure::error(format!("cannot read the run history: {error}")))?;
    let mut out = io::stdout().lock();
    if args.json {
        for record in &records {
            let _ = writeln!(out, "{}", record_json(record));
        }
    } else if records.is_empty() {
        let _ = writeln!(out, "No runs.");
    } else {
        for record in &records {
            let _ = write!(out, "{}", record_lines(record));
        }
    }
    Ok(0)
}

/// One run as a `--json` line: the record as stored, typed.
fn record_json(record: &RunRecord) -> Value {
    let mut value = json!({"type": "run"});
    if let (Some(line), Ok(Value::Object(fields))) =
        (value.as_object_mut(), serde_json::to_value(record))
    {
        line.extend(fields);
    }
    value
}

fn record_lines(record: &RunRecord) -> String {
    let name = match &record.profile {
        Some(profile) => format!("profile {profile}"),
        None => "ad hoc".to_owned(),
    };
    let mode = match record.mode {
        Mode::Interactive => "interactive",
        Mode::Batch => "batch",
        Mode::DryRun => "dry run",
    };
    let took = record.ended_ms.saturating_sub(record.started_ms);
    let stopped = if record.stopped { "  stopped" } else { "" };
    let mut lines = format!(
        "{}  {name}  {mode}  {}.{:03}s{stopped}\n",
        at(record.started_ms),
        took / 1000,
        took % 1000
    );
    for entry in &record.entries {
        lines.push_str(&entry_lines(entry));
    }
    lines
}

fn entry_lines(entry: &EntryRecord) -> String {
    let counts = &entry.counts;
    let ended = match entry.outcome {
        RecordedOutcome::Synced => {
            let mut said = format!(
                "synced: {} copied, {} deleted, {} committed, {} failed",
                counts.copied, counts.deleted, counts.committed, counts.failed
            );
            for (count, what) in [
                (counts.copied_aside, "copied aside"),
                (counts.skipped, "skipped"),
                (counts.conflicts, "conflict(s) open"),
                (counts.unreadable, "unreadable"),
            ] {
                if count > 0 {
                    said.push_str(&format!(", {count} {what}"));
                }
            }
            said
        }
        RecordedOutcome::Skipped => format!("skipped: {}", reason(entry)),
        RecordedOutcome::Failed => format!("failed: {}", reason(entry)),
        RecordedOutcome::NotRun => "not run".to_owned(),
    };
    let mut lines = format!("  {} ↔ {}  {ended}\n", entry.a, entry.b);
    if entry.reconnects > 0 {
        lines.push_str(&format!("    reconnects: {}\n", entry.reconnects));
    }
    for deleted in &entry.deleted {
        lines.push_str(&format!("    deleted {}\n", on(deleted)));
    }
    for overwritten in &entry.overwritten {
        lines.push_str(&format!("    overwrote {}\n", on(overwritten)));
    }
    for failure in &entry.failures {
        lines.push_str(&format!(
            "    failed {}: {}\n",
            failure.path, failure.message
        ));
    }
    lines
}

fn reason(entry: &EntryRecord) -> &str {
    entry.reason.as_deref().unwrap_or("(no reason recorded)")
}

fn on(side_path: &SidePath) -> String {
    format!(
        "on {}: {}",
        side_path.side.key().to_uppercase(),
        side_path.path
    )
}

fn at(unix_ms: u64) -> String {
    rfc3339(SystemTime::UNIX_EPOCH + Duration::from_millis(unix_ms))
        .unwrap_or_else(|| "(unrepresentable)".to_owned())
}
