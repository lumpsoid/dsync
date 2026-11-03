//! The scratch-file name a write streams into before renaming it over its
//! target (SPEC §7.2), the folder a replica's writes stage those in, and
//! the rule that recognises a scratch file again.
//!
//! A pure string rule shared by every writer (the replica writer, the
//! state-dir stores' atomic write) and by the scanner, which skips these
//! names: a crash leaves one behind, and a scan that reported it as a new
//! file would propagate dsync's own half-written data to the other
//! replica. They are skipped rather than deleted - removing files from a
//! replica unasked is not something a sync tool does on a guess about a
//! name.

/// The hidden folder at a folder replica's root where its writes create
/// their temps (SPEC §7.2). The scan skips it; leftovers are swept at lock.
pub const STAGING_DIR: &str = ".dsync-staging";

/// The staging folder of a single-file replica whose file is `file_name`:
/// `.dsync-staging.<file_name>`, beside the file (SPEC §7.2).
///
/// Named after the file rather than [`STAGING_DIR`]: a file replica locks
/// its file, not its folder, so a folder replica over the same folder - or
/// a file replica for another file in it - can lock and sweep alongside it,
/// and sweeping a shared staging folder would delete the other's in-flight
/// temps.
pub fn file_staging_dir_for(file_name: &str) -> String {
    format!("{STAGING_DIR}.{file_name}")
}

/// Whether `name` (one path segment at a folder replica's root) is a
/// staging folder: the replica's own, or a single-file replica's beside a
/// file in that folder. The scan skips both.
pub fn is_staging_dir_name(name: &str) -> bool {
    name.strip_prefix(STAGING_DIR)
        .is_some_and(|rest| rest.is_empty() || rest.len() > 1 && rest.starts_with('.'))
}

/// The lock file at a folder replica's root that excludes a run from
/// another installation over the same folder (SPEC §4.3). The scan skips
/// it, like the staging folder beside it.
pub const ROOT_LOCK_FILE: &str = ".dsync-lock";

/// The in-root lock file of a single-file replica whose file is
/// `file_name`: `.dsync-lock.<file_name>`, beside the file - named after
/// it for the reason [`file_staging_dir_for`] is.
pub fn file_root_lock_for(file_name: &str) -> String {
    format!("{ROOT_LOCK_FILE}.{file_name}")
}

/// Whether `name` (one path segment at a folder replica's root) is an
/// in-root lock file: the replica's own, or a single-file replica's beside
/// a file in that folder. The scan skips both.
pub fn is_root_lock_name(name: &str) -> bool {
    name.strip_prefix(ROOT_LOCK_FILE)
        .is_some_and(|rest| rest.is_empty() || rest.len() > 1 && rest.starts_with('.'))
}

/// Sits between the target's name and the parts that make it unique.
pub const TEMP_FILE_MARKER: &str = ".dsync-tmp.";

/// `<target_name>.dsync-tmp.<pid>.<sequence>`.
///
/// The writing process and a per-write sequence number rather than a fixed
/// name: two writers streaming into one fixed name would rename over each
/// other, and whether an atomic write is atomic should not depend on a
/// lock held elsewhere.
pub fn temp_name_for(target_name: &str, pid: u32, sequence: u64) -> String {
    format!("{target_name}{TEMP_FILE_MARKER}{pid}.{sequence}")
}

/// Whether `name` (one path segment) is a scratch file left by a write.
pub fn is_temp_file_name(name: &str) -> bool {
    let Some(at) = name.rfind(TEMP_FILE_MARKER) else {
        return false;
    };
    let digits = |part: &str| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit());
    match name[at + TEMP_FILE_MARKER.len()..].split_once('.') {
        Some((pid, sequence)) => digits(pid) && digits(sequence),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_built_name_is_recognised() {
        let name = temp_name_for("notes.txt", 4242, 7);
        assert_eq!(name, "notes.txt.dsync-tmp.4242.7");
        assert!(is_temp_file_name(&name));
    }

    #[test]
    fn ordinary_and_near_miss_names_are_not() {
        assert!(!is_temp_file_name("notes.txt"));
        assert!(!is_temp_file_name("notes.dsync-tmp."));
        assert!(!is_temp_file_name("notes.dsync-tmp.12"));
        assert!(!is_temp_file_name("notes.dsync-tmp.12."));
        assert!(!is_temp_file_name("notes.dsync-tmp.12.x"));
        assert!(!is_temp_file_name("notes.dsync-tmp.1.2.txt"));
        assert!(!is_temp_file_name("notes.dsync-tmp.a.2"));
    }

    #[test]
    fn both_staging_folder_names_are_recognised_and_near_misses_are_not() {
        assert!(is_staging_dir_name(STAGING_DIR));
        assert!(is_staging_dir_name(&file_staging_dir_for("notes.md")));
        assert_eq!(file_staging_dir_for("notes.md"), ".dsync-staging.notes.md");
        assert!(!is_staging_dir_name(".dsync-staging."));
        assert!(!is_staging_dir_name(".dsync-stagingx"));
        assert!(!is_staging_dir_name(".dsync-stag"));
        assert!(!is_staging_dir_name("notes.md"));
    }

    #[test]
    fn both_root_lock_names_are_recognised_and_near_misses_are_not() {
        assert!(is_root_lock_name(ROOT_LOCK_FILE));
        assert!(is_root_lock_name(&file_root_lock_for("notes.md")));
        assert_eq!(file_root_lock_for("notes.md"), ".dsync-lock.notes.md");
        assert!(!is_root_lock_name(".dsync-lock."));
        assert!(!is_root_lock_name(".dsync-lockx"));
        assert!(!is_root_lock_name(".dsync-loc"));
        assert!(!is_root_lock_name("notes.md"));
    }
}
