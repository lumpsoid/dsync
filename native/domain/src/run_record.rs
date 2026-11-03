//! What one profile run did, as its history keeps it: when it ran, what
//! it ran, and per entry how it ended, what it applied, and every path it
//! deleted, overwrote or failed on - so a file that changed can be traced
//! to the run that changed it after that run's output is gone.

use crate::rel_path::RelPath;
use crate::run_flags::Mode;
use crate::side::Side;

/// One run of a profile (or an ad-hoc pair), from its first entry to its
/// last.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRecord {
    /// Milliseconds since the Unix epoch.
    pub started_ms: u64,
    pub ended_ms: u64,
    /// `None` for an ad-hoc `dsync sync <locA> <locB>`.
    pub profile: Option<String>,
    pub mode: Mode,
    /// A stop was asked for before the run ended.
    pub stopped: bool,
    /// One per entry, in the order they ran.
    pub entries: Vec<EntryRecord>,
}

impl RunRecord {
    /// The diagnostics-log line a run of `entries` entries of `profile`
    /// starts with.
    pub fn started_diagnostic(profile: Option<&str>, mode: Mode, entries: usize) -> String {
        let what = match profile {
            Some(name) => format!("profile \"{name}\""),
            None => "an ad-hoc pair".to_owned(),
        };
        let noun = if entries == 1 { "entry" } else { "entries" };
        format!("run started: {what}, {}, {entries} {noun}", mode_word(mode))
    }

    /// The diagnostics-log lines this run ends with: one per entry, then
    /// how it ended. Counts and reasons only - no entry's locations and
    /// no path it touched, which stay the history's.
    pub fn ended_diagnostics(&self) -> Vec<String> {
        let total = self.entries.len();
        let mut lines: Vec<String> = self
            .entries
            .iter()
            .enumerate()
            .map(|(index, entry)| format!("entry {}/{total} {}", index + 1, entry.diagnostic()))
            .collect();
        let took = self.ended_ms.saturating_sub(self.started_ms);
        let how = if self.stopped { "stopped" } else { "ended" };
        lines.push(format!(
            "run {how} after {}.{:03} s",
            took / 1000,
            took % 1000
        ));
        lines
    }
}

fn mode_word(mode: Mode) -> &'static str {
    match mode {
        Mode::Interactive => "interactive",
        Mode::Batch => "batch",
        Mode::DryRun => "dry run",
    }
}

/// How one entry of a run went.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryRecord {
    pub entry_id: String,
    /// Each side's location, as the profile spells it.
    pub a: String,
    pub b: String,
    pub outcome: RecordedOutcome,
    /// Why it was skipped or failed; `None` when it synced or never ran.
    pub reason: Option<String>,
    pub counts: ActionCounts,
    /// Every file the run deleted, on the side it was deleted on.
    pub deleted: Vec<SidePath>,
    /// Every file the run replaced with the other side's version, on the
    /// side that was overwritten.
    pub overwritten: Vec<SidePath>,
    /// Every action that failed, and why.
    pub failures: Vec<RecordedFailure>,
    /// Times a dropped `peer://` side was dialled again.
    pub reconnects: u32,
}

impl EntryRecord {
    /// `<id>: <outcome>[ (<reason>)]; <counts>`, for the diagnostics log.
    fn diagnostic(&self) -> String {
        let outcome = match self.outcome {
            RecordedOutcome::Synced => "synced",
            RecordedOutcome::Skipped => "skipped",
            RecordedOutcome::Failed => "failed",
            RecordedOutcome::NotRun => "not run",
        };
        let reason = self
            .reason
            .as_ref()
            .map(|reason| format!(" ({reason})"))
            .unwrap_or_default();
        let ActionCounts {
            copied,
            copied_aside,
            deleted,
            committed,
            failed,
            skipped,
            conflicts,
            unreadable,
        } = self.counts;
        let counted: Vec<String> = [
            ("copied", copied),
            ("copied aside", copied_aside),
            ("deleted", deleted),
            ("committed", committed),
            ("failed", failed),
            ("skipped", skipped),
            ("conflicts", conflicts),
            ("unreadable", unreadable),
            ("reconnects", self.reconnects as usize),
        ]
        .into_iter()
        .filter(|&(_, count)| count > 0)
        .map(|(what, count)| format!("{what} {count}"))
        .collect();
        let counts = if counted.is_empty() {
            "nothing applied".to_owned()
        } else {
            counted.join(", ")
        };
        format!("{}: {outcome}{reason}; {counts}", self.entry_id)
    }
}

/// How an entry ended.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RecordedOutcome {
    Synced,
    Skipped,
    Failed,
    NotRun,
}

/// What an entry's apply did, action by action, and what its summary left
/// undone.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionCounts {
    pub copied: usize,
    pub copied_aside: usize,
    pub deleted: usize,
    pub committed: usize,
    pub failed: usize,
    /// Planned actions the decider did not keep.
    pub skipped: usize,
    /// Conflicts left unresolved.
    pub conflicts: usize,
    /// Paths a scan could not read.
    pub unreadable: usize,
}

/// A path on one side.
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct SidePath {
    pub side: Side,
    pub path: RelPath,
}

/// One failed action: its path, and the failure as the run reported it
/// (which names the side it was on).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct RecordedFailure {
    pub path: RelPath,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(outcome: RecordedOutcome, reason: Option<&str>, counts: ActionCounts) -> EntryRecord {
        EntryRecord {
            entry_id: "0123".to_owned(),
            a: "/home/me/Docs".to_owned(),
            b: "peer://phone/Docs".to_owned(),
            outcome,
            reason: reason.map(str::to_owned),
            counts,
            deleted: vec![SidePath {
                side: Side::B,
                path: RelPath::parse("secret.txt").unwrap(),
            }],
            overwritten: Vec::new(),
            failures: vec![RecordedFailure {
                path: RelPath::parse("private.txt").unwrap(),
                message: "denied".to_owned(),
            }],
            reconnects: 0,
        }
    }

    #[test]
    fn a_run_starts_with_what_it_runs() {
        assert_eq!(
            RunRecord::started_diagnostic(Some("docs"), Mode::Batch, 2),
            "run started: profile \"docs\", batch, 2 entries"
        );
        assert_eq!(
            RunRecord::started_diagnostic(None, Mode::DryRun, 1),
            "run started: an ad-hoc pair, dry run, 1 entry"
        );
    }

    #[test]
    fn a_run_ends_with_each_entrys_counts_and_no_paths() {
        let record = RunRecord {
            started_ms: 1_000,
            ended_ms: 3_250,
            profile: Some("docs".to_owned()),
            mode: Mode::Interactive,
            stopped: false,
            entries: vec![
                entry(
                    RecordedOutcome::Synced,
                    None,
                    ActionCounts {
                        copied: 3,
                        deleted: 1,
                        failed: 1,
                        ..ActionCounts::default()
                    },
                ),
                entry(
                    RecordedOutcome::Failed,
                    Some("the peer is unreachable"),
                    ActionCounts::default(),
                ),
            ],
        };
        let lines = record.ended_diagnostics();
        assert_eq!(
            lines,
            [
                "entry 1/2 0123: synced; copied 3, deleted 1, failed 1",
                "entry 2/2 0123: failed (the peer is unreachable); nothing applied",
                "run ended after 2.250 s",
            ]
        );
        for line in &lines {
            for private in ["Docs", "secret", "private", "denied"] {
                assert!(!line.contains(private), "{line}");
            }
        }
    }

    #[test]
    fn a_stopped_run_says_so() {
        let record = RunRecord {
            started_ms: 0,
            ended_ms: 5,
            profile: None,
            mode: Mode::Batch,
            stopped: true,
            entries: Vec::new(),
        };
        assert_eq!(record.ended_diagnostics(), ["run stopped after 0.005 s"]);
    }
}
