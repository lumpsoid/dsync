//! A `sync`/`status` invocation's flags, validated together.

use std::num::NonZeroUsize;

use crate::glob::Glob;
use crate::jobs::Jobs;
use crate::options_error::OptionsError;
use crate::ssh_access::{SshCommand, SshOption};

/// Which command the flags came with. `status` is `sync --dry-run` and has
/// no `--dry-run` flag of its own.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Command {
    Sync,
    Status,
}

/// The flag values as the argument parser read them: typed, but not yet
/// checked against each other or against their ranges. `ignore` and
/// `ssh_options` are additive (repeatable) flags.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Flags {
    pub dry_run: bool,
    pub batch: bool,
    pub json: bool,
    pub timings: bool,
    pub verbose: bool,
    pub quiet: bool,
    pub ignore: Vec<String>,
    pub warn_size: Option<i64>,
    pub jobs: Option<i64>,
    /// Hidden; benchmarks only.
    pub apply_concurrency: Option<i64>,
    pub ssh_options: Vec<String>,
    pub remote_dsync: Option<String>,
}

/// How the plan is decided.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// Ask about each action and conflict.
    Interactive,
    /// Apply non-conflicting actions without asking; list conflicts.
    Batch,
    /// Show the plan, apply nothing (`--dry-run`, and every `status`).
    DryRun,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Verbosity {
    Quiet,
    Normal,
    Verbose,
}

/// The flags once they are known to be consistent.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct RunFlags {
    pub mode: Mode,
    /// JSON Lines on stdout; only with [`Mode::Batch`] or [`Mode::DryRun`].
    pub json: bool,
    pub timings: bool,
    pub verbosity: Verbosity,
    pub ignore: Vec<Glob>,
    pub warn_size_bytes: Option<u64>,
    pub jobs: Option<Jobs>,
    /// `None` leaves the apply at its own default (`Tuning::writers`).
    pub apply_concurrency: Option<NonZeroUsize>,
    pub ssh_options: Vec<SshOption>,
    pub remote_dsync: Option<SshCommand>,
}

impl RunFlags {
    /// Checks `flags` for `command`. An empty `--ssh-option` or
    /// `--remote-dsync` would reach ssh as an argv word and fail far from
    /// the flag that caused it, so both are refused here, where the flag
    /// can be named.
    pub fn validate(command: Command, flags: Flags) -> Result<RunFlags, OptionsError> {
        let dry_run = flags.dry_run || command == Command::Status;
        let mode = match (flags.batch, dry_run) {
            (true, true) => return Err(OptionsError::BatchWithDryRun),
            (true, false) => Mode::Batch,
            (false, true) => Mode::DryRun,
            (false, false) => Mode::Interactive,
        };
        if flags.json && mode == Mode::Interactive {
            return Err(OptionsError::JsonNeedsBatchOrDryRun);
        }
        let verbosity = match (flags.verbose, flags.quiet) {
            (true, true) => return Err(OptionsError::VerboseWithQuiet),
            (true, false) => Verbosity::Verbose,
            (false, true) => Verbosity::Quiet,
            (false, false) => Verbosity::Normal,
        };
        let warn_size_bytes = flags
            .warn_size
            .map(|bytes| u64::try_from(bytes).map_err(|_| OptionsError::WarnSize(bytes)))
            .transpose()?;
        let jobs = flags
            .jobs
            .map(|count| Jobs::new(count).map_err(|_| OptionsError::Jobs(count)))
            .transpose()?;
        let apply_concurrency = flags
            .apply_concurrency
            .map(|count| {
                usize::try_from(count)
                    .ok()
                    .and_then(NonZeroUsize::new)
                    .ok_or(OptionsError::ApplyConcurrency(count))
            })
            .transpose()?;
        let ssh_options = flags
            .ssh_options
            .iter()
            .map(|option| SshOption::new(option).map_err(|_| OptionsError::EmptySshOption))
            .collect::<Result<_, _>>()?;
        let remote_dsync = flags
            .remote_dsync
            .map(|command| SshCommand::new(&command).map_err(|_| OptionsError::EmptyRemoteDsync))
            .transpose()?;
        let ignore = flags
            .ignore
            .iter()
            .map(|pattern| Glob::new(pattern))
            .collect::<Result<_, _>>()?;
        Ok(RunFlags {
            mode,
            json: flags.json,
            timings: flags.timings,
            verbosity,
            ignore,
            warn_size_bytes,
            jobs,
            apply_concurrency,
            ssh_options,
            remote_dsync,
        })
    }
}

#[cfg(test)]
mod tests {
    //! The cases of `test/cli/options/cli_options_test.dart` and
    //! `verbosity_test.dart` (a non-integer value is the argument parser's
    //! to refuse, phase 12), and the flag errors of
    //! `test/cli/sync_status_exit_code_test.dart` (each an exit 3 there).

    use super::*;

    fn sync(flags: Flags) -> Result<RunFlags, OptionsError> {
        RunFlags::validate(Command::Sync, flags)
    }

    #[test]
    fn no_flags_is_an_interactive_normal_run() {
        let flags = sync(Flags::default()).unwrap();
        assert_eq!(flags.mode, Mode::Interactive);
        assert_eq!(flags.verbosity, Verbosity::Normal);
        assert!(!flags.json);
        assert_eq!(flags.warn_size_bytes, None);
        assert_eq!(flags.jobs, None);
        assert_eq!(flags.apply_concurrency, None);
    }

    #[test]
    fn batch_with_dry_run_is_refused() {
        let flags = Flags {
            batch: true,
            dry_run: true,
            ..Flags::default()
        };
        assert_eq!(sync(flags), Err(OptionsError::BatchWithDryRun));
    }

    #[test]
    fn batch_with_status_is_refused_status_forces_dry_run() {
        let batch = Flags {
            batch: true,
            ..Flags::default()
        };
        assert_eq!(
            RunFlags::validate(Command::Status, batch.clone()),
            Err(OptionsError::BatchWithDryRun)
        );
        assert_eq!(sync(batch).map(|f| f.mode), Ok(Mode::Batch));
        assert_eq!(
            RunFlags::validate(Command::Status, Flags::default()).map(|f| f.mode),
            Ok(Mode::DryRun)
        );
    }

    #[test]
    fn json_needs_batch_or_dry_run() {
        let json = |batch, dry_run| Flags {
            json: true,
            batch,
            dry_run,
            ..Flags::default()
        };
        assert_eq!(
            sync(json(false, false)),
            Err(OptionsError::JsonNeedsBatchOrDryRun)
        );
        assert!(sync(json(true, false)).unwrap().json);
        assert!(sync(json(false, true)).unwrap().json);
        assert!(
            RunFlags::validate(Command::Status, json(false, false))
                .unwrap()
                .json
        );
    }

    #[test]
    fn verbose_with_quiet_is_refused() {
        let both = Flags {
            verbose: true,
            quiet: true,
            ..Flags::default()
        };
        assert_eq!(sync(both), Err(OptionsError::VerboseWithQuiet));
        let quiet = Flags {
            quiet: true,
            ..Flags::default()
        };
        assert_eq!(sync(quiet).unwrap().verbosity, Verbosity::Quiet);
    }

    #[test]
    fn warn_size_must_not_be_negative() {
        let warn = |bytes| Flags {
            warn_size: Some(bytes),
            ..Flags::default()
        };
        assert_eq!(sync(warn(-1)), Err(OptionsError::WarnSize(-1)));
        assert_eq!(sync(warn(0)).unwrap().warn_size_bytes, Some(0));
    }

    #[test]
    fn jobs_and_apply_concurrency_must_be_positive() {
        let jobs = |count| Flags {
            jobs: Some(count),
            ..Flags::default()
        };
        assert_eq!(sync(jobs(0)), Err(OptionsError::Jobs(0)));
        assert_eq!(sync(jobs(8)).unwrap().jobs.map(Jobs::get), Some(8));
        let apply = |count| Flags {
            apply_concurrency: Some(count),
            ..Flags::default()
        };
        assert_eq!(sync(apply(0)), Err(OptionsError::ApplyConcurrency(0)));
        assert_eq!(sync(apply(-3)), Err(OptionsError::ApplyConcurrency(-3)));
        assert_eq!(
            sync(apply(64))
                .unwrap()
                .apply_concurrency
                .map(NonZeroUsize::get),
            Some(64)
        );
    }

    #[test]
    fn empty_ssh_values_are_refused() {
        let option = Flags {
            ssh_options: vec!["-v".into(), String::new()],
            ..Flags::default()
        };
        assert_eq!(sync(option), Err(OptionsError::EmptySshOption));
        let command = Flags {
            remote_dsync: Some(String::new()),
            ..Flags::default()
        };
        assert_eq!(sync(command), Err(OptionsError::EmptyRemoteDsync));
        let fine = Flags {
            ssh_options: vec!["-p".into(), "2222".into()],
            remote_dsync: Some("/opt/bin/dsync".into()),
            ..Flags::default()
        };
        let fine = sync(fine).unwrap();
        let options: Vec<_> = fine.ssh_options.iter().map(SshOption::as_str).collect();
        assert_eq!(options, ["-p", "2222"]);
        assert_eq!(
            fine.remote_dsync.map(|c| c.to_string()),
            Some("/opt/bin/dsync".into())
        );
    }

    #[test]
    fn ignore_is_carried_in_order() {
        let flags = Flags {
            ignore: vec!["*.tmp".into(), "**/.git".into()],
            ..Flags::default()
        };
        let ignore: Vec<_> = sync(flags)
            .unwrap()
            .ignore
            .iter()
            .map(|g| g.as_str().to_owned())
            .collect();
        assert_eq!(ignore, ["*.tmp", "**/.git"]);
    }

    #[test]
    fn a_malformed_ignore_glob_is_refused() {
        let flags = Flags {
            ignore: vec!["[abc".into()],
            ..Flags::default()
        };
        assert!(matches!(sync(flags), Err(OptionsError::Ignore(_))));
    }
}
