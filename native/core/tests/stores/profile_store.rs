//! The profile store: the file cases of
//! `test/cli/profile/profile_loader_test.dart` (the key cases are the
//! domain's `Profile::parse` tests), and list / save / create / rename /
//! delete over real files.

use std::fs;
use std::path::PathBuf;

use dsync_core::{ProfileStore, ProfileStoreError};
use dsync_domain::{DirPath, DirRule, HostFacts, Platform, Profile, ProfileError, ProfileName};

use crate::support::names_in;

const EXAMPLE: &str = r#"
[[entries]]
a = "/home/me/notes"
b = "me@phone:/sdcard/notes"

[rules]
ignore = ["**/.git", "*.tmp"]

[options]
jobs = 4
"#;

fn name(text: &str) -> ProfileName {
    ProfileName::parse(text).unwrap()
}

fn profile(text: &str) -> Profile {
    Profile::parse(text, Platform::Unix).unwrap()
}

fn host(platform: Platform, home: Option<&str>, vars: &[(&str, &str)]) -> HostFacts {
    HostFacts::new(
        platform,
        home.map(str::to_owned),
        vars.iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned())),
        "/".into(),
    )
}

#[test]
fn loads_a_hand_written_profile_by_name() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    fs::create_dir_all(store.dir()).unwrap();
    fs::write(config.path().join("profiles/notes.toml"), EXAMPLE).unwrap();

    let loaded = store.load(&name("notes"), Platform::Unix).unwrap();

    assert_eq!(loaded, profile(EXAMPLE));
}

#[test]
fn a_missing_profile_file_is_fatal_naming_the_path() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    let error = store.load(&name("nope"), Platform::Unix).unwrap_err();
    let path = config.path().join("profiles/nope.toml");
    assert!(
        matches!(&error, ProfileStoreError::NotFound { path: p, .. } if *p == path),
        "{error:?}"
    );
    assert!(error.to_string().contains(&path.display().to_string()));
}

#[test]
fn an_invalid_profile_is_fatal_naming_the_file_and_the_reason() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    fs::create_dir_all(store.dir()).unwrap();
    let path = store.path(&name("broken"));
    for (text, expected) in [
        ("[[entries]\na = \"/a\"", "not valid TOML"),
        ("[[entries]]\na = \"/a\"\na = \"/b\"\n", "not valid TOML"),
        ("[[entries]]\na = \"/a\"\n", "entries[0].b is missing"),
        (
            "[[entries]]\na = \"/a\"\nb = \"/b\"\n[rules]\nignroe = []\n",
            "unknown key",
        ),
    ] {
        fs::write(&path, text).unwrap();
        let error = store.load(&name("broken"), Platform::Unix).unwrap_err();
        assert!(
            matches!(&error, ProfileStoreError::Invalid { path: p, .. } if *p == path),
            "{error:?}"
        );
        let message = error.to_string();
        assert!(message.contains(&path.display().to_string()), "{message}");
        assert!(message.contains(expected), "{message}");
    }
}

#[test]
fn a_profile_of_another_major_is_refused_naming_the_file_and_both_versions() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    fs::create_dir_all(store.dir()).unwrap();
    let path = store.path(&name("later"));
    fs::write(&path, format!("version = \"2.0\"\n{EXAMPLE}")).unwrap();

    let error = store.load(&name("later"), Platform::Unix).unwrap_err();
    let message = error.to_string();
    assert!(
        matches!(
            &error,
            ProfileStoreError::Invalid {
                source: ProfileError::ForeignVersion { .. },
                ..
            }
        ),
        "{error:?}"
    );
    assert!(message.contains(&path.display().to_string()), "{message}");
    assert!(message.contains("format 2.0"), "{message}");
    assert!(message.contains("(format 1.0)"), "{message}");
}

#[test]
fn a_profile_of_a_later_minor_loads_with_its_additions_ignored() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    fs::create_dir_all(store.dir()).unwrap();
    let later = format!("version = \"1.2\"\n{EXAMPLE}\n[notify]\non_conflict = true\n");
    fs::write(store.path(&name("later")), later).unwrap();

    let loaded = store.load(&name("later"), Platform::Unix).unwrap();

    assert_eq!(loaded, profile(EXAMPLE));
}

#[test]
fn a_saved_profile_round_trips_through_its_file() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    let original = profile(EXAMPLE);

    store.save(&name("notes"), &original).unwrap();

    assert_eq!(
        store.load(&name("notes"), Platform::Unix).unwrap(),
        original
    );
    assert_eq!(names_in(store.dir()), ["notes.toml"]);
}

#[test]
fn save_replaces_and_create_refuses_an_existing_name() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    let first = profile(EXAMPLE);
    let edited = profile("[[entries]]\na = \"/x\"\nb = \"/y\"\n");
    store.create(&name("notes"), &first).unwrap();

    assert!(matches!(
        store.create(&name("notes"), &edited),
        Err(ProfileStoreError::Exists { .. })
    ));
    assert_eq!(store.load(&name("notes"), Platform::Unix).unwrap(), first);

    store.save(&name("notes"), &edited).unwrap();
    assert_eq!(store.load(&name("notes"), Platform::Unix).unwrap(), edited);
}

#[test]
fn lists_profile_names_sorted_and_nothing_that_is_not_a_profile() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    assert!(store.list().unwrap().is_empty());

    for profile_name in ["work", "Notes", "photos 2024"] {
        store.save(&name(profile_name), &profile(EXAMPLE)).unwrap();
    }
    for stray in [
        "notes.toml.dsync-tmp.1.2",
        "README.md",
        ".hidden.toml",
        "-x.toml",
    ] {
        fs::write(store.dir().join(stray), "").unwrap();
    }
    fs::create_dir(store.dir().join("dir.toml")).unwrap();

    assert_eq!(
        store.list().unwrap(),
        [name("Notes"), name("photos 2024"), name("work")]
    );
}

#[test]
fn rename_moves_the_profile_and_refuses_a_taken_or_missing_name() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    let notes = profile(EXAMPLE);
    store.save(&name("notes"), &notes).unwrap();
    store
        .save(
            &name("work"),
            &profile("[[entries]]\na = \"/w\"\nb = \"/v\"\n"),
        )
        .unwrap();

    assert!(matches!(
        store.rename(&name("notes"), &name("work")),
        Err(ProfileStoreError::Exists { .. })
    ));
    assert!(matches!(
        store.rename(&name("ghost"), &name("other")),
        Err(ProfileStoreError::NotFound { .. })
    ));
    store.rename(&name("notes"), &name("notes")).unwrap();

    store.rename(&name("notes"), &name("journal")).unwrap();

    assert_eq!(store.list().unwrap(), [name("journal"), name("work")]);
    assert_eq!(store.load(&name("journal"), Platform::Unix).unwrap(), notes);
}

#[test]
fn delete_removes_the_file_and_refuses_a_missing_name() {
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    store.save(&name("notes"), &profile(EXAMPLE)).unwrap();

    store.delete(&name("notes")).unwrap();

    assert!(store.list().unwrap().is_empty());
    assert!(matches!(
        store.delete(&name("notes")),
        Err(ProfileStoreError::NotFound { .. })
    ));
}

#[test]
fn a_name_that_is_not_file_safe_never_reaches_the_store() {
    for bad in [
        "", "a/b", "..", ".notes", "-rf", "notes.", "CON", "a\\b", "x:y",
    ] {
        assert!(ProfileName::parse(bad).is_err(), "{bad:?}");
    }
    // Positive control.
    assert!(ProfileName::parse("notes 2.0").is_ok());
}

// Config-dir resolution (`resolveProfilePath`).

#[test]
fn resolves_under_xdg_config_home_and_falls_back_to_dot_config() {
    let with_xdg = host(
        Platform::Unix,
        Some("/home/me"),
        &[("XDG_CONFIG_HOME", "/xdg/config")],
    );
    let store = ProfileStore::resolve(&DirRule::Xdg, &with_xdg).unwrap();
    assert_eq!(
        store.path(&name("notes")),
        PathBuf::from("/xdg/config/dsync/profiles/notes.toml")
    );

    for unset in [vec![], vec![("XDG_CONFIG_HOME", "")]] {
        let fallback = host(Platform::Unix, Some("/home/me"), &unset);
        let store = ProfileStore::resolve(&DirRule::Xdg, &fallback).unwrap();
        assert_eq!(
            store.path(&name("notes")),
            PathBuf::from("/home/me/.config/dsync/profiles/notes.toml")
        );
    }
}

#[test]
fn resolves_under_the_macos_and_windows_config_dirs() {
    let mac = host(Platform::Unix, Some("/Users/me"), &[]);
    assert_eq!(
        ProfileStore::resolve(&DirRule::MacOs, &mac)
            .unwrap()
            .path(&name("notes")),
        PathBuf::from("/Users/me/Library/Application Support/dsync/profiles/notes.toml")
    );
    let windows = host(
        Platform::Windows,
        None,
        &[("APPDATA", "C:/Users/me/AppData/Roaming")],
    );
    assert_eq!(
        ProfileStore::resolve(&DirRule::Windows, &windows)
            .unwrap()
            .dir(),
        PathBuf::from("C:/Users/me/AppData/Roaming/dsync/profiles")
    );
    let supplied = DirRule::HostSupplied(DirPath::parse("/data/app/files").unwrap());
    assert_eq!(
        ProfileStore::resolve(&supplied, &host(Platform::Unix, None, &[]))
            .unwrap()
            .dir(),
        PathBuf::from("/data/app/files/dsync/profiles")
    );
}

#[test]
fn a_missing_variable_is_propagated_unchanged() {
    let bare = host(Platform::Unix, None, &[]);
    let error = ProfileStore::resolve(&DirRule::Xdg, &bare).unwrap_err();
    assert_eq!(Err(error), dsync_domain::config_dir(&DirRule::Xdg, &bare));
    assert!(ProfileStore::resolve(&DirRule::Windows, &bare).is_err());
}

#[test]
fn a_profile_error_is_the_domains() {
    // The store adds the path; the reason is `Profile::parse`'s own.
    let config = tempfile::tempdir().unwrap();
    let store = ProfileStore::new(config.path());
    fs::create_dir_all(store.dir()).unwrap();
    fs::write(store.path(&name("x")), "[[entries]]\nb = \"/b\"\n").unwrap();
    match store.load(&name("x"), Platform::Unix) {
        Err(ProfileStoreError::Invalid { source, .. }) => {
            assert_eq!(
                source,
                ProfileError::MissingLocation {
                    entry: 0,
                    side: dsync_domain::Side::A
                }
            );
        }
        other => panic!("{other:?}"),
    }
}
