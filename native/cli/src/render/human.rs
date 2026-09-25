//! Human mode (SPEC §11.4): the run header, the plan table, progress, the
//! summary; failures on stderr. `--quiet` keeps the summary and errors,
//! `--verbose` adds the preamble, the scan tallies and each status's
//! reason.

use std::io::Write;
use std::path::Path;
use std::time::SystemTime;

use dsync_core::{LockError, PeerContact, ReplicaError, RunError, RunEvent};
use dsync_domain::{
    Action, Conflict, ReplicaInfo, RunSummary, ScanTally, Side, SkippedPath, SkippedReason, Status,
    Verbosity,
};
use time::OffsetDateTime;
use time::macros::format_description;

use super::words;
use super::{RunName, RunView, Wallclock};

pub struct HumanRenderer<'v, O: Write, E: Write> {
    out: O,
    err: E,
    verbosity: Verbosity,
    view: &'v RunView,
    clock: Wallclock,
    /// Lines under each side's header row: SPEC §4.4's certificate expiry
    /// warnings for a `peer://` side, known once it is dialled.
    notes: Vec<(Side, String)>,
}

impl<'v, O: Write, E: Write> HumanRenderer<'v, O, E> {
    pub fn new(
        out: O,
        err: E,
        verbosity: Verbosity,
        view: &'v RunView,
        clock: Wallclock,
    ) -> HumanRenderer<'v, O, E> {
        HumanRenderer {
            out,
            err,
            verbosity,
            view,
            clock,
            notes: Vec::new(),
        }
    }

    /// What dialling learned about each `peer://` side, for the header.
    pub fn peer_contacts(&mut self, peers: &[PeerContact]) {
        self.notes = peers
            .iter()
            .flat_map(|peer| {
                peer.expiries
                    .iter()
                    .map(|expiry| (peer.side, expiry.to_string()))
            })
            .collect();
    }

    /// `--verbose` only: the merged rules, and how each side is reached.
    pub fn preamble(&mut self) {
        if self.verbosity != Verbosity::Verbose {
            return;
        }
        let rules = &self.view.rules;
        let globs = |globs: &[dsync_domain::Glob]| {
            globs
                .iter()
                .map(|glob| glob.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        };
        let _ = writeln!(
            self.out,
            "rules: ignore=[{}] follow=[{}]",
            globs(rules.ignore()),
            globs(rules.follow())
        );
        for side in Side::BOTH {
            let replica = self.view.replica(side);
            if let Some(lock) = &replica.lock {
                let _ = writeln!(self.out, "lock {}: {}", words::side(side), lock.display());
            }
            if let Some(args) = &replica.ssh_args {
                let _ = writeln!(self.out, "ssh {}: {}", words::side(side), args.join(" "));
            }
        }
    }

    pub fn render(&mut self, event: &RunEvent) {
        let quiet = self.verbosity == Verbosity::Quiet;
        match event {
            RunEvent::Summary(summary) => self.summary(summary),
            RunEvent::Error(error) => self.error(error),
            _ if quiet => {}
            RunEvent::Replicas {
                a,
                b,
                last_run_unfinished,
            } => self.replicas(a, b, *last_run_unfinished),
            RunEvent::ScanTally { a, b } => {
                if self.verbosity == Verbosity::Verbose {
                    self.scan_tally(Side::A, a);
                    self.scan_tally(Side::B, b);
                }
            }
            RunEvent::Skipped { side, skipped } => self.skipped(*side, skipped),
            RunEvent::Conflict(conflict) => self.conflict(conflict),
            RunEvent::Plan {
                plan,
                exceeds_warn_size,
            } => {
                let _ = writeln!(
                    self.out,
                    "plan: {} action(s), {} conflict(s), {} byte(s) to transfer",
                    plan.actions.len(),
                    plan.conflicts.len(),
                    plan.bytes_to_transfer()
                );
                for action in plan.actions.iter().map(|p| &p.action) {
                    let _ = writeln!(self.out, "  {}  {}", words::action(action), action.path());
                }
                if let (true, Some(limit)) = (*exceeds_warn_size, self.view.warn_size_bytes) {
                    let _ = writeln!(
                        self.out,
                        "warning: plan will transfer {} byte(s), over warn_size_bytes ({limit}) \
                         (SPEC §10)",
                        plan.bytes_to_transfer()
                    );
                }
            }
            RunEvent::Action(action) => {
                let _ = writeln!(self.out, "> {}  {}", words::action(action), action.path());
            }
            RunEvent::Result { action, outcome } => self.result(action, outcome),
            RunEvent::Progress { completed, total } => {
                let _ = writeln!(self.out, "  [{completed}/{total}]");
            }
        }
    }

    fn replicas(&mut self, a: &ReplicaInfo, b: &ReplicaInfo, last_run_unfinished: bool) {
        let label = match &self.view.name {
            RunName::Profile(name) => {
                let _ = writeln!(self.out, "profile {name}");
                String::new()
            }
            RunName::AdHoc => format!("{} · ", self.view.profile_id),
        };
        for (side, info) in [(Side::A, a), (Side::B, b)] {
            let replica = self.view.replica(side);
            let _ = writeln!(
                self.out,
                "{}  {}  {}",
                words::side(side),
                replica.location,
                replica.transport().label()
            );
            for (_, note) in self.notes.iter().filter(|(noted, _)| *noted == side) {
                let _ = writeln!(self.out, "   {note}");
            }
            if self.verbosity == Verbosity::Verbose
                && let Some(archive) = &info.archive_path
            {
                let _ = writeln!(self.out, "   archive {}: {archive}", words::side(side));
            }
        }
        match (a.last_commit, b.last_commit) {
            (None, None) => {
                let _ = writeln!(self.out, "  {label}first sync of this pair");
                self.first_sync_note();
            }
            (None, Some(_)) | (Some(_), None) => {
                let empty = if a.last_commit.is_none() { "A" } else { "B" };
                let _ = writeln!(
                    self.out,
                    "  {label}first sync of this pair ({empty} has no archive yet — a wiped \
                     state dir, or a new replica joining an established one)"
                );
                self.first_sync_note();
            }
            (Some(last_a), Some(last_b)) => {
                let synced = self.last_synced(last_a, last_b);
                let _ = writeln!(self.out, "  {label}{synced}");
            }
        }
        if last_run_unfinished {
            let _ = writeln!(
                self.out,
                "! The last run of this profile did not finish. This run picks up after it:\n  \
                 files it never reached sync as usual, and a file it stopped mid-write\n  comes \
                 back as a conflict marked interrupted."
            );
        }
    }

    fn first_sync_note(&mut self) {
        let _ = writeln!(
            self.out,
            "! First sync: with no archive, a file present on one side only is copied,\n  never \
             deleted — there is no way yet to tell a new file from a deleted one."
        );
    }

    fn last_synced(&self, a: SystemTime, b: SystemTime) -> String {
        let (shown_a, shown_b) = (self.timestamp(a), self.timestamp(b));
        if shown_a == shown_b {
            return format!("last synced {shown_a} ({})", self.ago(a));
        }
        format!(
            "last synced A {shown_a} ({}), B {shown_b} ({})",
            self.ago(a),
            self.ago(b)
        )
    }

    fn timestamp(&self, at: SystemTime) -> String {
        OffsetDateTime::from(at)
            .to_offset(self.clock.offset)
            .format(format_description!("[year]-[month]-[day] [hour]:[minute]"))
            .unwrap_or_else(|_| "?".to_owned())
    }

    fn ago(&self, at: SystemTime) -> String {
        let seconds = self
            .clock
            .now
            .duration_since(at)
            .map_or(0, |elapsed| elapsed.as_secs());
        match seconds {
            s if s >= 86_400 => format!("{} day(s) ago", s / 86_400),
            s if s >= 3_600 => format!("{} hour(s) ago", s / 3_600),
            s if s >= 60 => format!("{} minute(s) ago", s / 60),
            _ => "just now".to_owned(),
        }
    }

    fn scan_tally(&mut self, side: Side, tally: &ScanTally) {
        let _ = writeln!(
            self.out,
            "scan {}: {} path(s) scanned, {} rehashed to confirm unchanged",
            words::side(side),
            tally.total(),
            tally.hash_matched
        );
    }

    fn skipped(&mut self, side: Side, skipped: &SkippedPath) {
        let side = words::side(side);
        let at = words::skipped_at(&skipped.at);
        let detail = &skipped.detail;
        let _ = match skipped.reason {
            SkippedReason::Symlink => writeln!(self.out, "symlink  {side}  {at}  ({detail})"),
            SkippedReason::Unreadable => {
                writeln!(
                    self.out,
                    "unreadable  {side}  {at}  ({detail} — not synced)"
                )
            }
            SkippedReason::CaseFoldCollision => {
                writeln!(self.out, "case-fold  {side}  {at}  ({detail} — not synced)")
            }
            SkippedReason::UnrepresentableName => {
                writeln!(
                    self.out,
                    "unrepresentable  {side}  {at}  ({detail} — not synced)"
                )
            }
        };
    }

    fn conflict(&mut self, conflict: &Conflict) {
        let interrupted = if conflict.interrupted() {
            "  interrupted, may be incomplete"
        } else {
            ""
        };
        let _ = writeln!(
            self.out,
            "conflict  {}  (A: {}, B: {}){interrupted}",
            conflict.path,
            self.describe(conflict.a.as_ref()),
            self.describe(conflict.b.as_ref())
        );
    }

    fn describe(&self, status: Option<&Status>) -> String {
        match status {
            None => "absent".to_owned(),
            Some(status) if self.verbosity == Verbosity::Verbose => {
                format!("{} [{}]", words::status(status), words::reason_text(status))
            }
            Some(status) => words::status(status).to_owned(),
        }
    }

    fn result(&mut self, action: &Action, outcome: &Result<(), dsync_core::ActionFailure>) {
        let _ = match outcome {
            Ok(()) => writeln!(
                self.out,
                "  applied  {}  {}",
                words::action(action),
                action.path()
            ),
            Err(failure) => writeln!(
                self.out,
                "  failed   {}  {}: {failure}",
                words::action(action),
                action.path()
            ),
        };
    }

    fn summary(&mut self, summary: &RunSummary) {
        let _ = writeln!(self.out, "{}", summary_line(summary));
    }

    fn error(&mut self, error: &RunError) {
        let replica = |side: Side| {
            format!(
                "replica {} ({})",
                words::side(side),
                self.view.replica(side).location
            )
        };
        if let Some((side, lock)) = held_lock(error) {
            let _ = writeln!(
                self.err,
                "error: {} is in use by another dsync process on this machine (lock: {}).\n\
                 Wait for that run to finish, or stop it, then run this again.",
                replica(side),
                lock.display()
            );
            return;
        }
        let _ = match error {
            RunError::MissingRoot(missing) => {
                let device = self.view.replica(missing.side).device();
                writeln!(self.err, "error: {}", missing.describe(device.as_deref()))
            }
            other => writeln!(self.err, "error: {other}"),
        };
    }
}

/// The side and lock file of a lock another holder has.
fn held_lock(error: &RunError) -> Option<(Side, &Path)> {
    match error {
        RunError::Replica { side, source, .. } => match &**source {
            ReplicaError::Lock(LockError::Held { path }) => Some((*side, path)),
            _ => None,
        },
        _ => None,
    }
}

/// `summary: applied=… skipped=… conflicts=… failed=… unreadable=…`, the
/// line `benchmark/pairs/run_counts.dart` parses.
pub fn summary_line(summary: &RunSummary) -> String {
    format!(
        "summary: applied={} skipped={} conflicts={} failed={} unreadable={}",
        summary.applied, summary.skipped, summary.conflicts, summary.failed, summary.unreadable
    )
}

#[cfg(test)]
mod tests;
