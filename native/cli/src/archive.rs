//! `dsync archive` (SPEC §8.1, §8.3, §11.1): the archive logs in this
//! host's state directory, listed with what they cost, or deleted so the
//! next run over those replicas starts with no history.

use std::collections::BTreeSet;
use std::io::{self, Write};

use dsync_core::{
    ArchiveDeleteError, ArchiveInventory, LockError, ProfileStore, ProfileStoreError, StateDir,
    StoredArchive,
};
use dsync_domain::{DirRule, ProfileId, ProfileName};
use serde_json::{Value, json};

use crate::args::{ArchiveClearArgs, ArchiveCommand, ClearTarget, ListArgs, StateDirArgs};
use crate::failure::Failure;
use crate::host::Host;
use crate::render::rfc3339;

/// Runs `dsync archive <command>`, returning its exit code.
pub fn archive(command: ArchiveCommand, host: &Host) -> Result<u8, Failure> {
    match command {
        ArchiveCommand::List(args) => list(&args, host),
        ArchiveCommand::Clear(args) => clear(&args, host),
    }
}

fn inventory(args: &StateDirArgs, host: &Host) -> Result<ArchiveInventory, Failure> {
    let state = StateDir::resolve(&args.choice()?, &host.facts).map_err(Failure::error)?;
    Ok(ArchiveInventory::new(state))
}

fn stored(inventory: &ArchiveInventory) -> Result<Vec<StoredArchive>, Failure> {
    inventory
        .list()
        .map_err(|error| Failure::error(format!("cannot list the archives: {error}")))
}

/// `dsync archive list`: every log and its size, then the total - a fact
/// about the answer, so a reader wanting only the sum need not add rows.
fn list(args: &ListArgs, host: &Host) -> Result<u8, Failure> {
    let archives = stored(&inventory(&args.state, host)?)?;
    let total: u64 = archives.iter().map(|archive| archive.size_bytes).sum();
    let mut out = io::stdout().lock();
    if args.json {
        for archive in &archives {
            let _ = writeln!(out, "{}", archive_json(archive));
        }
        let total = json!({"type": "archiveTotal", "count": archives.len(), "sizeBytes": total});
        let _ = writeln!(out, "{total}");
    } else if archives.is_empty() {
        let _ = writeln!(out, "No archives.");
    } else {
        for archive in &archives {
            let _ = writeln!(out, "{}", archive_line(archive));
        }
        let _ = writeln!(out, "{} archive(s), {total} byte(s) total.", archives.len());
    }
    Ok(0)
}

fn archive_line(archive: &StoredArchive) -> String {
    format!(
        "{}  {}  {} byte(s)  root: {}  last commit: {}",
        archive.profile_id,
        archive.side,
        archive.size_bytes,
        archive
            .root_path
            .as_deref()
            .unwrap_or("(no readable header)"),
        rfc3339(archive.last_modified).unwrap_or_else(|| "(unrepresentable)".to_owned())
    )
}

/// One log as a `--json` line. An unreadable header is `rootPath: null`,
/// written rather than omitted: it is the fact a reader most needs.
fn archive_json(archive: &StoredArchive) -> Value {
    json!({
        "type": "archive",
        "profileId": archive.profile_id.as_str(),
        "side": archive.side.key(),
        "logPath": archive.log_path.to_string_lossy(),
        "rootPath": archive.root_path,
        "sizeBytes": archive.size_bytes,
        "lastModified": rfc3339(archive.last_modified),
    })
}

/// `dsync archive clear <profile> | --all`: both sides of a profile are
/// one decision - one side's history kept without the other's records a
/// propagation the other no longer remembers. Stops at a log a run holds,
/// having said what it freed so far.
fn clear(args: &ArchiveClearArgs, host: &Host) -> Result<u8, Failure> {
    let target = args.target()?;
    let inventory = inventory(&args.state, host)?;
    let archives = stored(&inventory)?;
    let doomed: Vec<StoredArchive> = match &target {
        ClearTarget::All => archives,
        ClearTarget::Profile(named) => {
            let id = profile_id(named, host)?;
            archives
                .into_iter()
                .filter(|archive| Some(&archive.profile_id) == id.as_ref())
                .collect()
        }
    };
    if doomed.is_empty() {
        return match target {
            ClearTarget::All => {
                println!("No archives.");
                Ok(0)
            }
            ClearTarget::Profile(named) => Err(Failure::Fatal(format!(
                "dsync archive clear: no archive for profile \"{named}\"."
            ))),
        };
    }
    let mut freed = 0;
    for archive in &doomed {
        if let Err(error) = inventory.delete(&archive.profile_id, archive.side) {
            println!("freed: {freed} byte(s)");
            let busy = matches!(error, ArchiveDeleteError::Lock(LockError::Held { .. }));
            let note = if busy {
                " — a run is in progress."
            } else {
                ""
            };
            return Err(Failure::Fatal(format!(
                "dsync archive clear: {error}{note}"
            )));
        }
        freed += archive.size_bytes;
        println!(
            "deleted: {} ({} byte(s))",
            archive.log_path.display(),
            archive.size_bytes
        );
    }
    println!("freed: {freed} byte(s)");
    println!(
        "The next run over {} rescans and rehashes from scratch. No replica file was touched.",
        subject(&doomed)
    );
    Ok(0)
}

/// The profile `named` names: a profile of that name, else an id as
/// `archive list` prints it. `None` when it is neither, which has no
/// archive by definition.
fn profile_id(named: &str, host: &Host) -> Result<Option<ProfileId>, Failure> {
    if let Ok(name) = ProfileName::parse(named) {
        let facts = &host.facts;
        let store = ProfileStore::resolve(&DirRule::HOST, facts).map_err(Failure::error)?;
        match store.load(&name, facts.platform()) {
            Ok(profile) => return profile.id(facts).map(Some).map_err(Failure::error),
            Err(ProfileStoreError::NotFound { .. }) => {}
            Err(error) => return Err(Failure::error(error)),
        }
    }
    Ok(ProfileId::parse(named).ok())
}

/// What the next run is: over the one profile cleared, or over each of
/// the profiles `--all` turned out to cover.
fn subject(doomed: &[StoredArchive]) -> String {
    let profiles: BTreeSet<&ProfileId> = doomed.iter().map(|archive| &archive.profile_id).collect();
    match profiles.len() {
        1 => "this profile".to_owned(),
        count => format!("each of these {count} profiles"),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::time::{Duration, SystemTime};

    use dsync_domain::Side;

    use super::*;

    fn archive(id: &str, side: Side, root: Option<&str>) -> StoredArchive {
        StoredArchive {
            log_path: PathBuf::from(format!("/state/{id}-{side}.jsonl")),
            profile_id: ProfileId::parse(id).unwrap(),
            side,
            root_path: root.map(str::to_owned),
            size_bytes: 42,
            last_modified: SystemTime::UNIX_EPOCH + Duration::from_secs(1_789_470_000),
        }
    }

    const P1: &str = "0123456789abcdef0123456789abcdef";
    const P2: &str = "fedcba9876543210fedcba9876543210";

    #[test]
    fn a_line_names_the_profile_side_size_root_and_last_commit() {
        let line = archive_line(&archive(P1, Side::A, Some("/home/me/notes")));
        assert_eq!(
            line,
            format!("{P1}  a  42 byte(s)  root: /home/me/notes  last commit: 2026-09-15T11:00:00Z")
        );
        let headless = archive_line(&archive(P1, Side::B, None));
        assert!(
            headless.contains("root: (no readable header)"),
            "{headless}"
        );
    }

    #[test]
    fn a_json_line_writes_an_unreadable_root_as_null() {
        let line = archive_json(&archive(P1, Side::B, None));
        assert_eq!(line["type"], "archive");
        assert_eq!(line["profileId"], P1);
        assert_eq!(line["side"], "b");
        assert_eq!(line["logPath"], format!("/state/{P1}-b.jsonl"));
        assert_eq!(line["sizeBytes"], 42);
        assert!(line["rootPath"].is_null());
    }

    #[test]
    fn the_next_run_names_one_profile_or_counts_them() {
        let one = [archive(P1, Side::A, None), archive(P1, Side::B, None)];
        assert_eq!(subject(&one), "this profile");
        let two = [archive(P1, Side::A, None), archive(P2, Side::A, None)];
        assert_eq!(subject(&two), "each of these 2 profiles");
    }
}
