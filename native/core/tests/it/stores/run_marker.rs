//! `<state>/<profileId>.run`: present from before an apply until it
//! returns.

use dsync_core::{RunMarker, StateDir};

use crate::stores::support::profile;

#[test]
fn is_absent_until_created_and_after_deleted() {
    let dir = tempfile::tempdir().unwrap();
    let state = StateDir::new(dir.path().join("dsync"));
    let marker = RunMarker::new(state.run_marker(&profile()));
    assert!(!marker.is_present().unwrap());

    marker.create().unwrap();
    assert!(marker.is_present().unwrap());
    assert_eq!(std::fs::read(marker.path()).unwrap(), b"");

    marker.delete().unwrap();
    assert!(!marker.is_present().unwrap());
}

#[test]
fn deleting_a_marker_already_gone_is_not_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let marker = RunMarker::new(dir.path().join("x.run"));
    marker.delete().unwrap();
    marker.create().unwrap();
    marker.create().unwrap();
    marker.delete().unwrap();
    marker.delete().unwrap();
}
