//! Plan D0: with the XDG variables pointed at a temp dir, every store
//! writes under `dsync-rs/` and nothing else appears - so a Rust run never
//! touches the Dart core's `dsync/`.

use dsync_core::{ArchiveInventory, ArchiveStore, ReplicaLock, RunMarker, StateDir};
use dsync_domain::{
    ArchiveCommit, DirRule, HostFacts, Platform, Side, StateDirChoice, Tuning, config_dir,
};

use crate::support::{names_in, path, profile, upsert};

#[test]
fn every_store_writes_under_the_dsync_rs_leaf_only() {
    let home = tempfile::tempdir().unwrap();
    let state_home = home.path().join("state");
    let config_home = home.path().join("config");
    let host = HostFacts::new(
        Platform::HOST,
        Some(home.path().display().to_string()),
        [
            (
                "XDG_STATE_HOME".to_owned(),
                state_home.display().to_string(),
            ),
            (
                "XDG_CONFIG_HOME".to_owned(),
                config_home.display().to_string(),
            ),
        ],
        "/".into(),
    );
    let state = StateDir::resolve(&StateDirChoice::Rule(DirRule::Xdg), &host).unwrap();
    assert_eq!(state.path(), state_home.join("dsync-rs"));
    assert_eq!(
        config_dir(&DirRule::Xdg, &host).unwrap(),
        config_home.join("dsync-rs")
    );

    let _lock = ReplicaLock::acquire(&state.lock(&profile(), Side::A)).unwrap();
    RunMarker::new(state.run_marker(&profile()))
        .create()
        .unwrap();
    let mut store = ArchiveStore::open_replica(
        &state,
        &profile(),
        Side::A,
        "/home/me/notes".into(),
        &Tuning::DEFAULT,
    )
    .unwrap();
    store
        .commit([
            upsert("a.txt", crate::support::file(1, 1)),
            ArchiveCommit::Intent(path("b.txt")),
        ])
        .unwrap();
    store.compact().unwrap();
    drop(store);

    // Positive control: the stores did write, and where expected.
    assert_eq!(names_in(&state_home), ["dsync-rs"]);
    assert_eq!(
        names_in(state.path()).len(),
        3,
        "{:?}",
        names_in(state.path())
    );
    assert_eq!(ArchiveInventory::new(state).list().unwrap().len(), 1);
    assert_eq!(
        names_in(home.path()),
        ["state"],
        "nothing created a config dir"
    );
}
