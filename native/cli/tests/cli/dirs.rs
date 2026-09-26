//! Where a Rust run keeps its state (plan D0): under `dsync/`.

use crate::support::Site;

#[test]
fn a_run_on_the_default_dirs_creates_only_dsync_under_them() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.write("a/hello.txt", "hi");
    site.run(&["sync", &a, &b, "--batch"]).exits(0);

    assert_eq!(
        site.listing(&site.state_home()),
        ["dsync".to_owned()].into()
    );
    let state = site.listing(&site.state_dir());
    assert!(
        state.iter().any(|name| name.ends_with("-a.jsonl"))
            && state.iter().any(|name| name.ends_with("-b.jsonl")),
        "the run's archives are there: {state:?}"
    );
    assert!(
        !site.config_home().exists(),
        "an ad-hoc run reads no config and writes none"
    );
}

#[test]
fn a_profile_is_read_from_dsync_under_the_config_home() {
    let site = Site::new();
    let (a, b) = (site.root("a"), site.root("b"));
    site.profile("work", &format!("[[entries]]\na = \"{a}\"\nb = \"{b}\"\n"));
    site.run(&["sync", "work", "--batch"]).exits(0);
    assert_eq!(
        site.listing(&site.config_home()),
        ["dsync".to_owned()].into()
    );
    assert_eq!(
        site.listing(&site.state_home()),
        ["dsync".to_owned()].into()
    );
}
