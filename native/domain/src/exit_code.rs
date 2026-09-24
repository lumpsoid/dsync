//! SPEC §11.5's exit codes.

use crate::run_summary::RunSummary;

/// The two signals that stop a dsync process.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StopSignal {
    Sigint,
    Sigterm,
}

impl StopSignal {
    /// 128 + the signal number: what every shell and CI system reads as
    /// "killed by signal N". Not folded into 3, so retry logic does not
    /// retry a run the user asked to stop.
    pub fn exit_code(self) -> u8 {
        match self {
            StopSignal::Sigint => 130,
            StopSignal::Sigterm => 143,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            StopSignal::Sigint => "SIGINT",
            StopSignal::Sigterm => "SIGTERM",
        }
    }
}

/// One run, reduced to what picking an exit code needs. Every combination
/// resolves, including the two a well-behaved run never produces (a
/// summary and an error, or neither).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct RunOutcome {
    pub summary: Option<RunSummary>,
    /// A fatal error ended the run.
    pub errored: bool,
    /// The first stop signal received, if any.
    pub interrupted_by: Option<StopSignal>,
}

impl RunOutcome {
    /// ```text
    /// 0    all planned actions applied, no conflicts
    /// 1    completed, but paths were skipped, unreadable, or in conflict
    /// 2    completed, but actions failed (wins over 1)
    /// 3    fatal: no summary, or an error
    /// 130  interrupted by SIGINT
    /// 143  interrupted by SIGTERM
    /// ```
    /// A signal pre-empts everything: it is what the user did. `status`
    /// and a dry run get no special case: their proposed actions are all
    /// skipped, so pending work exits 1 - the point of `dsync status` in a
    /// cron job or a prompt.
    pub fn exit_code(&self) -> u8 {
        if let Some(signal) = self.interrupted_by {
            return signal.exit_code();
        }
        match self.summary {
            Some(_) if self.errored => 3,
            None => 3,
            Some(summary) if summary.failed > 0 => 2,
            Some(summary)
                if summary.skipped > 0 || summary.conflicts > 0 || summary.unreadable > 0 =>
            {
                1
            }
            Some(_) => 0,
        }
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/cli/exit_code_test.dart`, and the policy half of
    //! `test/cli/sync_status_exit_code_test.dart` (its argument cases are
    //! in `options`).

    use super::*;

    fn summary(
        applied: usize,
        failed: usize,
        conflicts: usize,
        skipped: usize,
        unreadable: usize,
    ) -> RunSummary {
        RunSummary {
            applied,
            skipped,
            conflicts,
            failed,
            unreadable,
        }
    }

    fn with(summary: RunSummary) -> u8 {
        RunOutcome {
            summary: Some(summary),
            ..RunOutcome::default()
        }
        .exit_code()
    }

    #[test]
    fn no_summary_and_an_error_is_fatal() {
        let outcome = RunOutcome {
            errored: true,
            ..RunOutcome::default()
        };
        assert_eq!(outcome.exit_code(), 3);
    }

    #[test]
    fn no_summary_and_no_error_is_fatal() {
        assert_eq!(RunOutcome::default().exit_code(), 3);
    }

    #[test]
    fn a_summary_and_an_error_is_fatal_error_wins() {
        let outcome = RunOutcome {
            summary: Some(summary(5, 0, 0, 0, 0)),
            errored: true,
            interrupted_by: None,
        };
        assert_eq!(outcome.exit_code(), 3);
    }

    #[test]
    fn failures_only_is_2() {
        assert_eq!(with(summary(2, 1, 0, 0, 0)), 2);
    }

    #[test]
    fn failures_and_skips_is_2() {
        assert_eq!(with(summary(1, 1, 0, 3, 0)), 2);
    }

    #[test]
    fn failures_and_conflicts_is_2() {
        assert_eq!(with(summary(1, 1, 2, 0, 0)), 2);
    }

    #[test]
    fn skipped_only_is_1() {
        assert_eq!(with(summary(4, 0, 0, 2, 0)), 1);
    }

    #[test]
    fn conflicts_only_is_1() {
        assert_eq!(with(summary(4, 0, 1, 0, 0)), 1);
    }

    #[test]
    fn conflicts_and_skips_is_1() {
        assert_eq!(with(summary(4, 0, 1, 2, 0)), 1);
    }

    #[test]
    fn unreadable_only_is_1_never_2() {
        assert_eq!(with(summary(4, 0, 0, 0, 1)), 1);
        assert_eq!(with(summary(4, 0, 0, 0, 3)), 1);
    }

    #[test]
    fn a_failure_and_an_unreadable_path_is_2() {
        assert_eq!(with(summary(1, 1, 0, 0, 1)), 2);
    }

    #[test]
    fn everything_applied_is_0() {
        assert_eq!(with(summary(7, 0, 0, 0, 0)), 0);
    }

    /// A dry run applies nothing, so every proposed action is skipped.
    #[test]
    fn a_status_or_dry_run_with_pending_work_exits_1() {
        assert_eq!(with(summary(0, 0, 0, 3, 0)), 1);
    }

    #[test]
    fn a_status_or_dry_run_with_nothing_pending_exits_0() {
        assert_eq!(with(RunSummary::default()), 0);
    }

    #[test]
    fn interrupted_with_nothing_else_is_130_not_3() {
        let outcome = RunOutcome {
            interrupted_by: Some(StopSignal::Sigint),
            ..RunOutcome::default()
        };
        assert_eq!(outcome.exit_code(), 130);
    }

    #[test]
    fn interrupted_by_sigterm_is_143() {
        let bare = RunOutcome {
            interrupted_by: Some(StopSignal::Sigterm),
            ..RunOutcome::default()
        };
        assert_eq!(bare.exit_code(), 143);
        let with_failures = RunOutcome {
            summary: Some(summary(2, 1, 0, 0, 0)),
            errored: false,
            interrupted_by: Some(StopSignal::Sigterm),
        };
        assert_eq!(with_failures.exit_code(), 143);
        assert_eq!(StopSignal::Sigterm.label(), "SIGTERM");
    }

    #[test]
    fn interrupted_wins_over_a_clean_summary() {
        let outcome = RunOutcome {
            summary: Some(summary(7, 0, 0, 0, 0)),
            errored: false,
            interrupted_by: Some(StopSignal::Sigint),
        };
        assert_eq!(outcome.exit_code(), 130);
    }

    #[test]
    fn interrupted_wins_over_failures() {
        let outcome = RunOutcome {
            summary: Some(summary(2, 1, 0, 0, 0)),
            errored: false,
            interrupted_by: Some(StopSignal::Sigint),
        };
        assert_eq!(outcome.exit_code(), 130);
    }

    #[test]
    fn interrupted_wins_over_a_fatal_error() {
        let outcome = RunOutcome {
            summary: None,
            errored: true,
            interrupted_by: Some(StopSignal::Sigint),
        };
        assert_eq!(outcome.exit_code(), 130);
    }

    #[test]
    fn not_interrupted_falls_back_to_the_ordinary_scheme() {
        assert_eq!(with(summary(3, 0, 0, 0, 0)), 0);
    }
}
