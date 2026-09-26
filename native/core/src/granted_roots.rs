//! The folders a paired peer was granted, as the bound on the links a
//! replica served to it goes through (SPEC §4.4, §5.1).

use std::path::{Path, PathBuf};

use dsync_domain::PeerName;

use crate::paired_device::PairedDevice;

/// The roots granted to `peer`. A link on a replica served to it is
/// followed only when its fully resolved target lies inside one of them.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct GrantedRoots {
    peer: PeerName,
    roots: Vec<PathBuf>,
}

impl GrantedRoots {
    pub fn new(peer: PeerName, roots: Vec<PathBuf>) -> GrantedRoots {
        GrantedRoots { peer, roots }
    }

    /// What `device` was granted, as its grants name the roots.
    pub fn of(device: &PairedDevice) -> GrantedRoots {
        GrantedRoots::new(
            device.name().clone(),
            device.granted_roots().iter().map(PathBuf::from).collect(),
        )
    }

    pub fn peer(&self) -> &PeerName {
        &self.peer
    }

    pub fn roots(&self) -> &[PathBuf] {
        &self.roots
    }

    /// The same peer's roots, each replaced by what `resolve` makes of it.
    pub(crate) fn map_roots(self, resolve: impl Fn(PathBuf) -> PathBuf) -> GrantedRoots {
        GrantedRoots {
            peer: self.peer,
            roots: self.roots.into_iter().map(resolve).collect(),
        }
    }

    /// Whether `resolved`, a path with every link in it already resolved,
    /// is one of the roots or lies beneath one. Compared by path
    /// components, so `/a/b` does not contain `/a/bc`.
    pub fn contain(&self, resolved: &Path) -> bool {
        self.roots.iter().any(|root| resolved.starts_with(root))
    }

    /// Why a link whose target is outside every root is not followed.
    pub fn outside(&self) -> String {
        format!("target outside the folders granted to {}", self.peer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn granted(roots: &[&str]) -> GrantedRoots {
        GrantedRoots::new(
            PeerName::parse("phone").unwrap(),
            roots.iter().map(PathBuf::from).collect(),
        )
    }

    #[test]
    fn a_root_and_what_lies_beneath_it_are_inside() {
        let grants = granted(&["/a/b", "/c"]);
        assert!(grants.contain(Path::new("/a/b")));
        assert!(grants.contain(Path::new("/a/b/x/y.txt")));
        assert!(grants.contain(Path::new("/c/z")));
    }

    #[test]
    fn a_sibling_sharing_a_prefix_is_outside() {
        let grants = granted(&["/a/b"]);
        assert!(!grants.contain(Path::new("/a/bc")));
        assert!(!grants.contain(Path::new("/a/bc/x.txt")));
        assert!(!grants.contain(Path::new("/a")));
    }

    #[test]
    fn nothing_is_inside_no_grants() {
        assert!(!granted(&[]).contain(Path::new("/a/b")));
    }

    #[test]
    fn a_trailing_separator_on_a_grant_changes_nothing() {
        let grants = granted(&["/a/b/"]);
        assert!(grants.contain(Path::new("/a/b/x")));
        assert!(!grants.contain(Path::new("/a/bc")));
    }

    #[test]
    fn the_reason_names_the_peer() {
        assert_eq!(
            granted(&[]).outside(),
            "target outside the folders granted to phone"
        );
    }
}
