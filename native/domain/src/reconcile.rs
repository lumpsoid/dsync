//! Two replicas' status lists in, a plan out (SPEC §6).

use std::collections::{BTreeMap, BTreeSet, HashSet};

use crate::action::Action;
use crate::conflict::Conflict;
use crate::plan::Plan;
use crate::rel_path::RelPath;
use crate::scan_entry::{FileState, ScanEntry, Status, Unchanged};
use crate::side::Side;
use crate::unreadable_paths::UnreadablePaths;

#[cfg(test)]
mod tests;

/// Reconciles side A's and side B's status lists into a [`Plan`] sorted by
/// path.
///
/// A path absent from a list means that side has neither the file nor an
/// archive entry: it has never seen the path. That survives the §6.1
/// exchange dropping entries, because a path is either absent from both
/// lists or present in every list that has a status for it.
///
/// `unreadable` holds what neither list can express: paths a scan could
/// not read or disambiguate (both sides' skipped paths). Everything it
/// covers is left out entirely - no action, no conflict - because the
/// unreadable side's silence would otherwise read as "never seen" and
/// mirror the other side's copy over a file the tool never looked at.
pub fn reconcile(a: Vec<ScanEntry>, b: Vec<ScanEntry>, unreadable: &UnreadablePaths) -> Plan {
    let a = by_path(a);
    let b = by_path(b);
    let files_a = present_paths(&a);
    let files_b = present_paths(&b);
    let dirs_a = implied_dirs(&files_a);
    let dirs_b = implied_dirs(&files_b);

    let mut plan = Plan::default();
    let paths: BTreeSet<&RelPath> = a.keys().chain(b.keys()).collect();
    for path in paths {
        if unreadable.covers(path) {
            continue;
        }
        // Beneath a path that is a file on some side: that ancestor's own
        // type-mismatch conflict covers it until it is settled.
        if has_file_ancestor(path, &files_a) || has_file_ancestor(path, &files_b) {
            continue;
        }
        let (on_a, on_b) = (a.get(path), b.get(path));
        let conflict = || Conflict {
            path: path.clone(),
            a: on_a.copied(),
            b: on_b.copied(),
        };
        // A file on one side and a directory with files on the other.
        if is_file_vs_dir(on_a, path, &dirs_b) || is_file_vs_dir(on_b, path, &dirs_a) {
            plan.conflicts.push(conflict());
            continue;
        }
        match resolve(seen(on_a), seen(on_b)) {
            Verdict::Nothing => {}
            Verdict::Conflict => plan.conflicts.push(conflict()),
            Verdict::CommitOnly => plan.actions.push(Action::CommitOnly { path: path.clone() }),
            Verdict::DeleteOn(on) => plan.actions.push(Action::Delete {
                path: path.clone(),
                on,
            }),
            Verdict::CopyFrom(from, source) => plan.actions.push(Action::Copy {
                path: path.clone(),
                from,
                bytes: source.meta.size,
            }),
        }
    }
    plan
}

/// One path's outcome, before it is given its path.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Verdict<'a> {
    Nothing,
    CopyFrom(Side, &'a FileState),
    DeleteOn(Side),
    CommitOnly,
    Conflict,
}

/// What one side says about a path, `Silent` when it has no entry. Flat so
/// the table below reads as SPEC §6's grid; the mapping from [`Status`]
/// is exhaustive, so a new status fails to compile here and then in the
/// table.
#[derive(Clone, Copy)]
enum Seen<'a> {
    Silent,
    Unchanged(&'a FileState),
    Created(&'a FileState),
    Modified(&'a FileState),
    Deleted,
    Untrusted(&'a FileState),
    UntrustedAbsent,
}

fn seen(status: Option<&Status>) -> Seen<'_> {
    match status {
        None => Seen::Silent,
        Some(Status::Unchanged {
            file,
            by: Unchanged::MetadataMatched | Unchanged::HashMatched,
        }) => Seen::Unchanged(file),
        Some(Status::Created(file)) => Seen::Created(file),
        Some(Status::Modified(file)) => Seen::Modified(file),
        Some(Status::Deleted) => Seen::Deleted,
        Some(Status::Untrusted(file)) => Seen::Untrusted(file),
        Some(Status::UntrustedAbsent) => Seen::UntrustedAbsent,
    }
}

/// SPEC §6's table plus its additional rules, one cell per pair of what A
/// and B say. No wildcard arm: every pair is written out.
fn resolve<'a>(a: Seen<'a>, b: Seen<'a>) -> Verdict<'a> {
    use Seen::*;
    use Verdict::{CommitOnly, CopyFrom, DeleteOn, Nothing};
    let same_or_conflict = |x: &FileState, y: &FileState| {
        if x.hash == y.hash {
            CommitOnly
        } else {
            Verdict::Conflict
        }
    };
    let same_or_copy = |from: Side, source: &'a FileState, other: &FileState| {
        if source.hash == other.hash {
            CommitOnly
        } else {
            CopyFrom(from, source)
        }
    };
    match (a, b) {
        (Silent, Silent) => Nothing,

        // Never seen on one side: mirror whatever the other has...
        (Unchanged(f) | Created(f) | Modified(f), Silent) => CopyFrom(Side::A, f),
        (Silent, Unchanged(f) | Created(f) | Modified(f)) => CopyFrom(Side::B, f),
        // ...or, when the other reports it deleted, it is gone everywhere
        // (a side still holding the file would say `created`, never be
        // silent): tombstone the side still recording it.
        (Deleted, Silent) | (Silent, Deleted) => CommitOnly,

        // Neither changed. Same hash is the steady state; different hashes
        // are two archives that silently diverged, and no rule can pick a
        // direction.
        (Unchanged(x), Unchanged(y)) => {
            if x.hash == y.hash {
                Nothing
            } else {
                Verdict::Conflict
            }
        }
        (Unchanged(x), Created(y) | Modified(y)) => same_or_copy(Side::B, y, x),
        (Created(x) | Modified(x), Unchanged(y)) => same_or_copy(Side::A, x, y),
        (Unchanged(_), Deleted) => DeleteOn(Side::A),
        (Deleted, Unchanged(_)) => DeleteOn(Side::B),

        (Created(x) | Modified(x), Created(y) | Modified(y)) => same_or_conflict(x, y),
        (Created(_) | Modified(_), Deleted) | (Deleted, Created(_) | Modified(_)) => {
            Verdict::Conflict
        }
        (Deleted, Deleted) => CommitOnly,

        // Untrusted (SPEC §7.6) is not in the table. On both sides it is
        // unreachable by construction (a marked side is never a copy's
        // source), so the user decides.
        (Untrusted(_) | UntrustedAbsent, Untrusted(_) | UntrustedAbsent) => Verdict::Conflict,
        // A marked file holding the other side's content: the write
        // finished and only its commit was lost.
        (Untrusted(u), Unchanged(o) | Created(o) | Modified(o))
        | (Unchanged(o) | Created(o) | Modified(o), Untrusted(u)) => same_or_conflict(u, o),
        // A marked file with nothing on the other side: deleting it could
        // destroy an edit, so the user decides.
        (Untrusted(_), Silent | Deleted) | (Silent | Deleted, Untrusted(_)) => Verdict::Conflict,
        // A mark with no file was never written: that side has never seen
        // the path, so mirror onto it, or with nothing to mirror clear the
        // mark.
        (UntrustedAbsent, Unchanged(o) | Created(o) | Modified(o)) => CopyFrom(Side::B, o),
        (Unchanged(o) | Created(o) | Modified(o), UntrustedAbsent) => CopyFrom(Side::A, o),
        (UntrustedAbsent, Silent | Deleted) | (Silent | Deleted, UntrustedAbsent) => CommitOnly,
    }
}

fn by_path(entries: Vec<ScanEntry>) -> BTreeMap<RelPath, Status> {
    entries.into_iter().map(|e| (e.path, e.status)).collect()
}

fn present_paths(entries: &BTreeMap<RelPath, Status>) -> HashSet<&str> {
    entries
        .iter()
        .filter(|(_, status)| status.is_present())
        .map(|(path, _)| path.as_str())
        .collect()
}

/// Every directory implied by `files`: `a/b/c.txt` implies `a` and `a/b`.
fn implied_dirs<'a>(files: &HashSet<&'a str>) -> HashSet<&'a str> {
    files.iter().flat_map(|file| ancestors(file)).collect()
}

fn ancestors(path: &str) -> impl Iterator<Item = &str> {
    path.match_indices('/').map(move |(end, _)| &path[..end])
}

fn has_file_ancestor(path: &RelPath, files: &HashSet<&str>) -> bool {
    ancestors(path.as_str()).any(|ancestor| files.contains(ancestor))
}

fn is_file_vs_dir(status: Option<&Status>, path: &RelPath, other_dirs: &HashSet<&str>) -> bool {
    status.is_some_and(Status::is_present) && other_dirs.contains(path.as_str())
}
