//! `<state>/<profileId>.run`: present from before an apply until it
//! returns, holding what that apply set out to write.

use dsync_core::{LastRun, MarkerRecord, RunMarker, StateDir};
use dsync_domain::{Action, RelPath, Side, UnfinishedApply};

use crate::stores::support::profile;

fn writes() -> UnfinishedApply {
    UnfinishedApply::of(&[Action::Copy {
        path: RelPath::parse("a\nline/f").unwrap(),
        from: Side::A,
        bytes: 3,
    }])
}

fn applying() -> MarkerRecord {
    MarkerRecord::Applying(writes())
}

#[test]
fn is_absent_until_created_and_after_deleted() {
    let dir = tempfile::tempdir().unwrap();
    let state = StateDir::new(dir.path().join("dsync"));
    let marker = RunMarker::new(state.run_marker(&profile()));
    assert_eq!(marker.last_run().unwrap(), LastRun::Settled);
    assert_eq!(marker.read().unwrap(), None);

    marker.create(&applying()).unwrap();
    assert_eq!(marker.last_run().unwrap(), LastRun::Died);
    assert_eq!(marker.read().unwrap(), Some(applying()));

    marker.delete().unwrap();
    assert_eq!(marker.last_run().unwrap(), LastRun::Settled);
    assert_eq!(marker.read().unwrap(), None);
}

#[test]
fn a_marker_a_finished_run_rewrote_says_a_write_is_held_not_that_it_died() {
    let dir = tempfile::tempdir().unwrap();
    let marker = RunMarker::new(dir.path().join("x.run"));
    marker.create(&MarkerRecord::Held(writes())).unwrap();
    assert_eq!(marker.last_run().unwrap(), LastRun::WriteHeld);
    assert_eq!(
        marker.read().unwrap().map(MarkerRecord::into_writes),
        Some(writes())
    );
}

#[test]
fn creating_again_replaces_the_record_by_rename_leaving_no_temp() {
    let dir = tempfile::tempdir().unwrap();
    let marker = RunMarker::new(dir.path().join("x.run"));
    marker
        .create(&MarkerRecord::Applying(UnfinishedApply::default()))
        .unwrap();
    marker.create(&applying()).unwrap();
    assert_eq!(marker.read().unwrap(), Some(applying()));
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
    assert_eq!(
        marker.read().unwrap(),
        Some(MarkerRecord::Applying(UnfinishedApply::default()))
    );
}

#[test]
fn deleting_a_marker_already_gone_is_not_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let marker = RunMarker::new(dir.path().join("x.run"));
    marker.delete().unwrap();
    marker.create(&applying()).unwrap();
    marker.create(&applying()).unwrap();
    marker.delete().unwrap();
    marker.delete().unwrap();
}
