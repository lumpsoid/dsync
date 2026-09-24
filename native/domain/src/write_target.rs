//! How a copy lands at its destination (SPEC §7.2, §7.6).

/// What is already at a copy's destination, as far as choosing how to
/// write it goes. The core probes the facts (read *through* a followed
/// symlink: the write lands on the target); this decides.
///
/// A copy writes in place (§7.6) unless that would change something the
/// user did not ask to sync, or would fail where a rename would not; those
/// fall back to a scratch file beside the target renamed over it:
///
/// - more than one hard link: an in-place write changes every name,
///   including ones outside the replica (§5.1: hard links are independent
///   files), while a rename repoints only this one;
/// - not writable: opening it would fail on every run, while a rename
///   needs only the directory's permission (§7.4 sets the mode after);
/// - unknown: a host whose facts could not be read gets the write that is
///   safe whatever they would have said.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum WriteTarget {
    /// Nothing there yet: no other names, nothing to refuse.
    Absent,
    Existing {
        link_count: u64,
        writable: bool,
    },
    Unknown {
        reason: String,
    },
}

/// The two ways a copy can land.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum WriteMode {
    /// Write the destination file itself, marked first (§7.6).
    InPlace,
    /// Write `.dsync-tmp.*` beside it, then rename over.
    TempAndRename,
}

impl WriteTarget {
    pub fn mode(&self) -> WriteMode {
        match self {
            WriteTarget::Absent => WriteMode::InPlace,
            WriteTarget::Existing {
                link_count,
                writable,
            } if *link_count <= 1 && *writable => WriteMode::InPlace,
            WriteTarget::Existing { .. } | WriteTarget::Unknown { .. } => WriteMode::TempAndRename,
        }
    }
}

#[cfg(test)]
mod tests {
    //! The pure choice behind `test/dsync_core/agent/write_target_probe_test.dart`
    //! (the probe itself is the core's).

    use super::*;

    fn existing(link_count: u64, writable: bool) -> WriteMode {
        WriteTarget::Existing {
            link_count,
            writable,
        }
        .mode()
    }

    #[test]
    fn nothing_there_writes_in_place() {
        assert_eq!(WriteTarget::Absent.mode(), WriteMode::InPlace);
    }

    #[test]
    fn a_plain_writable_file_with_one_link_writes_in_place() {
        assert_eq!(existing(1, true), WriteMode::InPlace);
    }

    #[test]
    fn a_hard_linked_file_is_replaced() {
        assert_eq!(existing(2, true), WriteMode::TempAndRename);
    }

    #[test]
    fn a_read_only_file_is_replaced() {
        assert_eq!(existing(1, false), WriteMode::TempAndRename);
        assert_eq!(existing(3, false), WriteMode::TempAndRename);
    }

    #[test]
    fn unknown_facts_get_the_safe_write() {
        let unknown = WriteTarget::Unknown {
            reason: "no binding for this ABI".into(),
        };
        assert_eq!(unknown.mode(), WriteMode::TempAndRename);
    }
}
