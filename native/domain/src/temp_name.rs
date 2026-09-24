//! The scratch-file name a write streams into before renaming it over its
//! target (SPEC §7.2), and the rule that recognises one again.
//!
//! A pure string rule shared by every writer (the replica writer, the
//! state-dir stores' atomic write) and by the scanner, which skips these
//! names: a crash leaves one behind, and a scan that reported it as a new
//! file would propagate dsync's own half-written data to the other
//! replica. They are skipped rather than deleted - removing files from a
//! replica unasked is not something a sync tool does on a guess about a
//! name.

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
}
