//! `<state>/<profileId>.run`: present from before an apply until it
//! returns, holding what that apply set out to write.

use dsync_core::{RunMarker, StateDir};
use dsync_domain::{Action, RelPath, Side, UnfinishedApply};

use crate::stores::support::profile;

fn writes() -> UnfinishedApply {
    UnfinishedApply::of(&[Action::Copy {
        path: RelPath::parse("a\nline/f").unwrap(),
        from: Side::A,
        bytes: 3,
    }])
}

#[test]
fn is_absent_until_created_and_after_deleted() {
    let dir = tempfile::tempdir().unwrap();
    let state = StateDir::new(dir.path().join("dsync"));
    let marker = RunMarker::new(state.run_marker(&profile()));
    assert!(!marker.is_present().unwrap());
    assert_eq!(marker.read().unwrap(), None);

    marker.create(&writes()).unwrap();
    assert!(marker.is_present().unwrap());
    assert_eq!(marker.read().unwrap(), Some(writes()));

    marker.delete().unwrap();
    assert!(!marker.is_present().unwrap());
    assert_eq!(marker.read().unwrap(), None);
}

#[test]
fn creating_again_replaces_the_record_by_rename_leaving_no_temp() {
    let dir = tempfile::tempdir().unwrap();
    let marker = RunMarker::new(dir.path().join("x.run"));
    marker.create(&UnfinishedApply::default()).unwrap();
    marker.create(&writes()).unwrap();
    assert_eq!(marker.read().unwrap(), Some(writes()));
    let names: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(names, ["x.run"]);
}

#[test]
fn a_marker_whose_record_does_not_parse_still_says_the_run_died() {
    let dir = tempfile::tempdir().unwrap();
    let marker = RunMarker::new(dir.path().join("x.run"));
    std::fs::write(marker.path(), b"{\"a\":[\"cut").unwrap();
    assert_eq!(marker.read().unwrap(), Some(UnfinishedApply::default()));
}

#[test]
fn deleting_a_marker_already_gone_is_not_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let marker = RunMarker::new(dir.path().join("x.run"));
    marker.delete().unwrap();
    marker.create(&UnfinishedApply::default()).unwrap();
    marker.create(&UnfinishedApply::default()).unwrap();
    marker.delete().unwrap();
    marker.delete().unwrap();
}
