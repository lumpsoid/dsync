//! The default decider (SPEC §11.3): each conflict, then each proposed
//! action, answered one line at a time. `a` accepts every remaining action
//! but never resolves a conflict (SPEC §6: conflicts are never
//! auto-resolved); `q` leaves everything not yet decided out; a closed
//! input is a `q`, the one answer that decides nothing on the user's
//! behalf.

use std::io::Write;

use dsync_core::Decider;
use dsync_domain::{Action, Conflict, Plan, Side, Status};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, Lines};
use tokio::sync::watch;

use crate::render::words;

/// Interactive review reads answers from stdin; with no one behind it,
/// "accept everything" would write the user's data on a decision nobody
/// made.
pub const NOT_A_TERMINAL: &str = "stdin is not a terminal, so there is no one to answer an \
                                  interactive prompt; rerun with --batch or --dry-run";

const LEGEND: &str = "Interactive review (SPEC §11.3) — one line of input per prompt:\n  \
                      y = accept        s = skip\n  \
                      a = accept all remaining (conflicts left unresolved, not resolved)\n  \
                      q = quit (stop asking; anything not yet decided is left out)\n\
                      A conflict with both sides present offers a direction instead of y:\n  \
                      1 = keep A (copy A -> B)   2 = keep B (copy B -> A)";

/// One answer to one prompt.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Answer {
    Accept,
    Keep(Side),
    Skip,
    AcceptAll,
    Quit,
}

impl Answer {
    fn key(self) -> &'static str {
        match self {
            Answer::Accept => "y",
            Answer::Keep(Side::A) => "1",
            Answer::Keep(Side::B) => "2",
            Answer::Skip => "s",
            Answer::AcceptAll => "a",
            Answer::Quit => "q",
        }
    }
}

const ACCEPT_OR_SKIP: &[Answer] = &[
    Answer::Accept,
    Answer::Skip,
    Answer::AcceptAll,
    Answer::Quit,
];
const DIRECTION: &[Answer] = &[
    Answer::Keep(Side::A),
    Answer::Keep(Side::B),
    Answer::Skip,
    Answer::AcceptAll,
    Answer::Quit,
];

/// Asks on `output` and reads answers from `input`.
pub struct InteractiveDecider<R, W> {
    input: Lines<R>,
    output: W,
    /// Set once the plan the prompts are about has been printed, so the
    /// legend never lands above it.
    plan_shown: watch::Receiver<bool>,
}

impl<R: AsyncBufRead + Unpin + Send, W: Write + Send> InteractiveDecider<R, W> {
    pub fn new(input: R, output: W, plan_shown: watch::Receiver<bool>) -> Self {
        InteractiveDecider {
            input: input.lines(),
            output,
            plan_shown,
        }
    }

    async fn review(&mut self, plan: &Plan) -> Vec<Action> {
        let mut kept = Vec::new();
        if plan.actions.is_empty() && plan.conflicts.is_empty() {
            return kept;
        }
        let _ = self.plan_shown.wait_for(|shown| *shown).await;
        let _ = writeln!(self.output, "{LEGEND}");
        let mut accept_all = false;
        for conflict in &plan.conflicts {
            match self.ask_conflict(conflict).await {
                Answer::Quit => return kept,
                Answer::AcceptAll => {
                    accept_all = true;
                    break;
                }
                Answer::Skip => {}
                Answer::Keep(side) => kept.push(conflict.resolve(side)),
                Answer::Accept => kept.push(conflict.resolve(only_side(conflict))),
            }
        }
        for action in &plan.actions {
            if accept_all {
                kept.push(action.clone());
                continue;
            }
            match self.ask_action(action).await {
                Answer::Quit => return kept,
                Answer::AcceptAll => {
                    accept_all = true;
                    kept.push(action.clone());
                }
                Answer::Skip => {}
                Answer::Accept | Answer::Keep(_) => kept.push(action.clone()),
            }
        }
        kept
    }

    async fn ask_conflict(&mut self, conflict: &Conflict) -> Answer {
        let _ = writeln!(self.output, "--- conflict: {}", conflict.path);
        let _ = writeln!(self.output, "  A: {}", describe(conflict.a.as_ref()));
        let _ = writeln!(self.output, "  B: {}", describe(conflict.b.as_ref()));
        if conflict.a.is_none() || conflict.b.is_none() {
            let only = words::prompt_action(&conflict.resolve(only_side(conflict)));
            let _ = write!(
                self.output,
                "  [y] accept ({only})  [s] skip  [a] accept all remaining  [q] quit > "
            );
            return self.read(ACCEPT_OR_SKIP).await;
        }
        let keep = |side| words::prompt_action(&conflict.resolve(side));
        let _ = write!(
            self.output,
            "  [1] keep A ({})  [2] keep B ({})  [s] skip  [a] accept all remaining  [q] quit > ",
            keep(Side::A),
            keep(Side::B)
        );
        self.read(DIRECTION).await
    }

    async fn ask_action(&mut self, action: &Action) -> Answer {
        let _ = writeln!(
            self.output,
            "--- {}: {}",
            words::prompt_action(action),
            action.path()
        );
        let _ = write!(
            self.output,
            "  [y] accept  [s] skip  [a] accept all remaining  [q] quit > "
        );
        self.read(ACCEPT_OR_SKIP).await
    }

    /// One line, re-asked until it is one of `valid`.
    async fn read(&mut self, valid: &[Answer]) -> Answer {
        let _ = self.output.flush();
        loop {
            let Ok(Some(line)) = self.input.next_line().await else {
                return Answer::Quit;
            };
            let key = line.trim().to_lowercase();
            if let Some(answer) = valid.iter().find(|answer| answer.key() == key) {
                return *answer;
            }
            let keys: Vec<_> = valid.iter().map(|answer| answer.key()).collect();
            let _ = writeln!(
                self.output,
                "Not understood: \"{line}\". Enter one of: {}.",
                keys.join("/")
            );
        }
    }
}

impl<R: AsyncBufRead + Unpin + Send, W: Write + Send> Decider for InteractiveDecider<R, W> {
    async fn decide(&mut self, plan: &Plan) -> Vec<Action> {
        self.review(plan).await
    }
}

/// The side a one-sided conflict has a record on: the only one to keep.
fn only_side(conflict: &Conflict) -> Side {
    if conflict.a.is_some() {
        Side::A
    } else {
        Side::B
    }
}

fn describe(status: Option<&Status>) -> String {
    match status {
        None => "(absent)".to_owned(),
        Some(status) => match status.file() {
            Some(file) => format!(
                "{}, {} bytes, hash {}",
                words::status(status),
                file.meta.size,
                file.hash
            ),
            None => words::status(status).to_owned(),
        },
    }
}

#[cfg(test)]
mod tests;
