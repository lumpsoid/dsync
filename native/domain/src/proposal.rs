//! A planned action and what undoing its direction would do (SPEC §6).

use crate::action::Action;
use crate::scan_entry::Status;
use crate::side::Side;

/// One action of a [`crate::Plan`], with its reversal when one is offered.
///
/// A reversal is what the reconciler would have planned had the user said
/// "the other side is right": the conflict resolution keeping the side the
/// action would overwrite or delete on (the loser). It is offered only when
/// that resolution is a copy - the loser holds a file - so an offered
/// reversal is always a copy of the same path from the loser, and only its
/// size is new information. `reverse_bytes` is that size; `None` means no
/// reversal is offered.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Proposal {
    pub action: Action,
    pub reverse_bytes: Option<u64>,
}

impl Proposal {
    /// Proposes `action` for a path whose sides say `a` and `b` (`None`:
    /// that side has never seen the path).
    pub fn of(action: Action, a: Option<&Status>, b: Option<&Status>) -> Self {
        let reverse_bytes = loser(&action)
            .and_then(|side| match side {
                Side::A => a,
                Side::B => b,
            })
            .and_then(Status::file)
            .map(|file| file.meta.size);
        Proposal {
            action,
            reverse_bytes,
        }
    }

    /// The action that puts the loser's version back, when offered.
    pub fn reversed(&self) -> Option<Action> {
        let from = loser(&self.action)?;
        let bytes = self.reverse_bytes?;
        Some(Action::Copy {
            path: self.action.path().clone(),
            from,
            bytes,
        })
    }
}

/// The side whose state `action` overrides: a copy's destination, a
/// delete's side. A commit-only overrides nothing, nor does a copy aside,
/// which writes a new path (the reconciler never proposes one).
fn loser(action: &Action) -> Option<Side> {
    match action {
        Action::Copy { from, .. } => Some(from.other()),
        Action::Delete { on, .. } => Some(*on),
        Action::CommitOnly { .. } | Action::CopyAside { .. } => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rel_path::RelPath;

    fn path() -> RelPath {
        RelPath::parse("x").unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn a_reversal_copies_from_the_loser_with_its_size() {
        let copy = Proposal {
            action: Action::Copy {
                path: path(),
                from: Side::A,
                bytes: 3,
            },
            reverse_bytes: Some(7),
        };
        assert_eq!(
            copy.reversed(),
            Some(Action::Copy {
                path: path(),
                from: Side::B,
                bytes: 7
            })
        );
        let delete = Proposal {
            action: Action::Delete {
                path: path(),
                on: Side::A,
            },
            reverse_bytes: Some(5),
        };
        assert_eq!(
            delete.reversed(),
            Some(Action::Copy {
                path: path(),
                from: Side::A,
                bytes: 5
            })
        );
        let unoffered = Proposal {
            reverse_bytes: None,
            ..copy
        };
        assert_eq!(unoffered.reversed(), None);
        let commit = Proposal {
            action: Action::CommitOnly { path: path() },
            reverse_bytes: Some(1),
        };
        assert_eq!(commit.reversed(), None);
    }
}
