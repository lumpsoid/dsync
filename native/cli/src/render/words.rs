//! How the CLI spells the core's values: the human words and the JSON
//! names (SPEC §11.4). One place, so the two renderers and the interactive
//! prompt never disagree about what an action or a status is called.

use dsync_domain::{Action, Side, SkippedAt, SkippedReason, Status, Unchanged};

/// `A` or `B`, as every human line names a side.
pub fn side(side: Side) -> &'static str {
    match side {
        Side::A => "A",
        Side::B => "B",
    }
}

/// The run's plan-table label: `copy A→B`, `copy B→A aside as <to>`,
/// `delete on B`, `commit only`.
pub fn action(action: &Action) -> String {
    match action {
        Action::Copy { from, .. } => format!("copy {}→{}", side(*from), side(from.other())),
        Action::CopyAside { from, to, .. } => {
            format!("copy {}→{} aside as {to}", side(*from), side(from.other()))
        }
        Action::Delete { on, .. } => format!("delete on {}", side(*on)),
        Action::CommitOnly { .. } => "commit only".to_owned(),
    }
}

/// The interactive prompt's label: `copy A -> B` in plain ASCII, typed
/// against.
pub fn prompt_action(action: &Action) -> String {
    match action {
        Action::Copy { from, .. } => format!("copy {} -> {}", side(*from), side(from.other())),
        Action::CopyAside { from, to, .. } => {
            format!(
                "copy {} -> {} aside as {to}",
                side(*from),
                side(from.other())
            )
        }
        Action::Delete { on, .. } => format!("delete on {}", side(*on)),
        Action::CommitOnly { .. } => "commit only (same content)".to_owned(),
    }
}

/// The JSON `actionType`.
pub fn action_type(action: &Action) -> &'static str {
    match action {
        Action::Copy { from: Side::A, .. } => "copyAtoB",
        Action::Copy { from: Side::B, .. } => "copyBtoA",
        Action::CopyAside { from: Side::A, .. } => "copyAsideAtoB",
        Action::CopyAside { from: Side::B, .. } => "copyAsideBtoA",
        Action::Delete { on: Side::A, .. } => "deleteOnA",
        Action::Delete { on: Side::B, .. } => "deleteOnB",
        Action::CommitOnly { .. } => "commitOnly",
    }
}

/// A status by SPEC §5.2's name.
pub fn status(status: &Status) -> &'static str {
    match status {
        Status::Unchanged { .. } => "unchanged",
        Status::Created(_) => "created",
        Status::Modified(_) => "modified",
        Status::Deleted => "deleted",
    }
}

/// The JSON name of the §5.2 branch behind a status.
pub fn reason(status: &Status) -> &'static str {
    match status {
        Status::Unchanged {
            by: Unchanged::MetadataMatched,
            ..
        } => "metadataMatched",
        Status::Unchanged {
            by: Unchanged::HashMatched,
            ..
        } => "hashMatched",
        Status::Created(_) => "created",
        Status::Modified(_) => "modified",
        Status::Deleted => "deleted",
    }
}

/// The same branch, explained, for `--verbose`.
pub fn reason_text(status: &Status) -> &'static str {
    match status {
        Status::Unchanged {
            by: Unchanged::MetadataMatched,
            ..
        } => "size/mtime matched archive, not rehashed",
        Status::Unchanged {
            by: Unchanged::HashMatched,
            ..
        } => "size/mtime drifted, rehash matched archive",
        Status::Modified(_) => "rehash differed from archive",
        Status::Created(_) => "no archive entry",
        Status::Deleted => "archive entry, file absent",
    }
}

/// The JSON `type` of a skipped path: one type per reason, never a shared
/// type with a field, so a consumer filtering for `symlink` - normal on
/// every run - never starts matching failures (SPEC §11.4).
pub fn skipped_type(reason: SkippedReason) -> &'static str {
    match reason {
        SkippedReason::Symlink => "symlink",
        SkippedReason::Unreadable => "unreadable",
        SkippedReason::CaseFoldCollision => "caseFoldCollision",
        SkippedReason::UnrepresentableName => "unrepresentableName",
        SkippedReason::SpecialFile => "specialFile",
    }
}

/// Where a skipped entry sits, spelled as a path: an unrepresentable name
/// under its folder.
pub fn skipped_at(at: &SkippedAt) -> String {
    match at {
        SkippedAt::Path(path) => path.to_string(),
        SkippedAt::UnrepresentableName {
            parent: Some(parent),
            name,
        } => format!("{parent}/{name}"),
        SkippedAt::UnrepresentableName { parent: None, name } => name.clone(),
    }
}
