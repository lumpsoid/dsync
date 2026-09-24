//! Whether the filesystem mounted at a replica root folds case (SPEC §3,
//! §16): asked of the filesystem, never assumed from the OS.

use std::fs::{self, OpenOptions};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use dsync_domain::CaseFolding;

/// Creates a lowercase marker file in `root` and asks whether its
/// uppercase spelling names it too, then removes it. Once per replica per
/// run: one create, one stat, one delete.
///
/// Best effort: a root this process cannot create a file in (missing, no
/// write permission) answers [`CaseFolding::Distinct`], rather than
/// failing a caller that only wanted a yes or no; such a root fails loudly
/// soon enough at the scan or the first write.
pub fn probe_case_folding(root: &Path) -> CaseFolding {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    // Every letter lowercase, so the uppercase spelling really differs.
    let name = format!(".dsync-case-probe-{}-{nanos}", std::process::id());
    let marker = root.join(&name);
    if OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&marker)
        .is_err()
    {
        return CaseFolding::Distinct;
    }
    let folds = root.join(name.to_uppercase()).exists();
    // Best effort: the answer is in hand, and a leftover dotfile is a
    // smaller problem than losing it.
    let _ = fs::remove_file(&marker);
    if folds {
        CaseFolding::Folds
    } else {
        CaseFolding::Distinct
    }
}
