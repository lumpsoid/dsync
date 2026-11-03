//! An entry's [`EntryRecord`], gathered from its runs' events as they go
//! by: every attempt's applied actions, and which of its copies landed on
//! a file that was there.

use std::collections::HashSet;

use dsync_domain::{
    Action, ActionCounts, EffectiveOptions, EntryRecord, Plan, RecordedFailure, RecordedOutcome,
    RelPath, Side, SidePath, Status,
};

use super::{EntryOutcome, EntryReport, listed};
use crate::run::RunEvent;

/// One entry's record so far, over all its attempts.
#[derive(Default)]
pub(super) struct EntryRecorder {
    /// Where a plan found a file a copy would land on.
    occupied: HashSet<(Side, RelPath)>,
    counts: ActionCounts,
    deleted: Vec<SidePath>,
    overwritten: Vec<SidePath>,
    failures: Vec<RecordedFailure>,
}

impl EntryRecorder {
    pub(super) fn observe(&mut self, event: &RunEvent) {
        match event {
            RunEvent::Plan { plan, .. } => self.note_occupied(plan),
            RunEvent::Result {
                action,
                outcome: Ok(()),
            } => self.applied(action),
            RunEvent::Result {
                action,
                outcome: Err(failure),
            } => {
                self.counts.failed += 1;
                self.failures.push(RecordedFailure {
                    path: action.path().clone(),
                    message: failure.to_string(),
                });
            }
            _ => {}
        }
    }

    /// A planned copy over a file offers its reversal; a conflict holds
    /// each side's file, which a resolution copies over.
    fn note_occupied(&mut self, plan: &Plan) {
        for proposal in &plan.actions {
            if let (Action::Copy { path, from, .. }, Some(_)) =
                (&proposal.action, proposal.reverse_bytes)
            {
                self.occupied.insert((from.other(), path.clone()));
            }
        }
        for conflict in &plan.conflicts {
            for side in Side::BOTH {
                if conflict.on(side).and_then(Status::file).is_some() {
                    self.occupied.insert((side, conflict.path.clone()));
                }
            }
        }
    }

    fn applied(&mut self, action: &Action) {
        match action {
            Action::Copy { path, from, .. } => {
                self.counts.copied += 1;
                let side = from.other();
                if self.occupied.contains(&(side, path.clone())) {
                    self.overwritten.push(SidePath {
                        side,
                        path: path.clone(),
                    });
                }
            }
            Action::CopyAside { .. } => self.counts.copied_aside += 1,
            Action::Delete { path, on } => {
                self.counts.deleted += 1;
                self.deleted.push(SidePath {
                    side: *on,
                    path: path.clone(),
                });
            }
            Action::CommitOnly { .. } => self.counts.committed += 1,
        }
    }

    /// The record of `options`' entry, which ended as `report` says.
    pub(super) fn finish(self, options: &EffectiveOptions, report: &EntryReport) -> EntryRecord {
        let mut counts = self.counts;
        let (outcome, reason) = match &report.outcome {
            EntryOutcome::Synced(summary) => {
                counts.skipped = summary.skipped;
                counts.conflicts = summary.conflicts;
                counts.unreadable = summary.unreadable;
                (RecordedOutcome::Synced, None)
            }
            EntryOutcome::Skipped(reason) => (RecordedOutcome::Skipped, Some(reason.to_string())),
            EntryOutcome::Failed(failure) => (RecordedOutcome::Failed, Some(failure.to_string())),
            EntryOutcome::NotRun => (RecordedOutcome::NotRun, None),
        };
        let listed = listed(options);
        EntryRecord {
            entry_id: listed.entry_id.as_str().to_owned(),
            a: listed.a,
            b: listed.b,
            outcome,
            reason,
            counts,
            deleted: self.deleted,
            overwritten: self.overwritten,
            failures: self.failures,
            reconnects: report.reconnects,
        }
    }
}

#[cfg(test)]
mod tests {
    use dsync_domain::{
        Conflict, ConflictCause, ContentHash, FileMeta, FileState, Proposal, RootKind,
    };

    use super::*;
    use crate::run::ActionFailure;

    fn path(text: &str) -> RelPath {
        RelPath::parse(text).unwrap()
    }

    fn copy(text: &str, from: Side) -> Action {
        Action::Copy {
            path: path(text),
            from,
            bytes: 1,
        }
    }

    fn applied(action: Action) -> RunEvent {
        RunEvent::Result {
            action,
            outcome: Ok(()),
        }
    }

    #[test]
    fn a_copy_over_a_file_is_an_overwrite_and_onto_nothing_is_not() {
        let mut recorder = EntryRecorder::default();
        let plan = Plan {
            actions: vec![
                Proposal {
                    action: copy("over", Side::A),
                    reverse_bytes: Some(3),
                },
                Proposal {
                    action: copy("new", Side::A),
                    reverse_bytes: None,
                },
            ],
            conflicts: Vec::new(),
        };
        recorder.observe(&RunEvent::Plan {
            plan,
            exceeds_warn_size: false,
        });
        recorder.observe(&applied(copy("over", Side::A)));
        recorder.observe(&applied(copy("new", Side::A)));
        assert_eq!(recorder.counts.copied, 2);
        assert_eq!(
            recorder.overwritten,
            vec![SidePath {
                side: Side::B,
                path: path("over"),
            }]
        );
    }

    #[test]
    fn a_resolved_conflict_overwrites_the_side_not_kept() {
        let mut recorder = EntryRecorder::default();
        let file = Status::Modified(FileState {
            meta: FileMeta {
                size: 1,
                mtime_us: 0,
                mode: 0o644,
                read_us: 0,
            },
            hash: ContentHash::from_digest([1; 32]),
        });
        recorder.observe(&RunEvent::Plan {
            plan: Plan {
                actions: Vec::new(),
                conflicts: vec![Conflict {
                    path: path("both"),
                    a: Some(file),
                    b: Some(file),
                    root_kind: RootKind::Folder,
                    cause: ConflictCause::Changes,
                }],
            },
            exceeds_warn_size: false,
        });
        recorder.observe(&applied(copy("both", Side::B)));
        assert_eq!(
            recorder.overwritten,
            vec![SidePath {
                side: Side::A,
                path: path("both"),
            }]
        );
    }

    #[test]
    fn counts_deletes_commits_and_failures_by_path() {
        let mut recorder = EntryRecorder::default();
        recorder.observe(&applied(Action::Delete {
            path: path("gone"),
            on: Side::B,
        }));
        recorder.observe(&applied(Action::CommitOnly { path: path("same") }));
        recorder.observe(&RunEvent::Result {
            action: copy("stuck", Side::A),
            outcome: Err(ActionFailure::ChangedDuringSync { side: Side::B }),
        });
        let counts = recorder.counts;
        assert_eq!(
            (
                counts.copied,
                counts.deleted,
                counts.committed,
                counts.failed
            ),
            (0, 1, 1, 1)
        );
        assert_eq!(
            recorder.deleted,
            vec![SidePath {
                side: Side::B,
                path: path("gone"),
            }]
        );
        assert_eq!(recorder.failures[0].path, path("stuck"));
        assert!(
            recorder.failures[0].message.contains("changed during sync"),
            "{}",
            recorder.failures[0].message
        );
    }
}
