//! The OQ6 derivation: one id per canonical replica pair.

use super::*;
use crate::location::Location;

const HOME: &str = "/home/me";

fn facts_in(cwd: &str) -> HostFacts {
    HostFacts::new(
        Platform::Unix,
        Some(HOME.to_owned()),
        [("DATA".to_owned(), "/srv/data".to_owned())],
        cwd.to_owned(),
    )
}

fn facts() -> HostFacts {
    facts_in("/work")
}

fn device(key: &[u8]) -> DeviceId {
    DeviceId::from_spki_der(key)
}

fn replica(raw: &str, device: Option<DeviceId>) -> ReplicaLocation {
    let location = Location::parse(raw, Platform::Unix).unwrap_or_else(|e| panic!("{e}"));
    ReplicaLocation::new(location, device).unwrap_or_else(|e| panic!("{e}"))
}

fn side_with(raw: &str, device: Option<DeviceId>, facts: &HostFacts) -> CanonicalSide {
    CanonicalSide::of(&replica(raw, device), facts).unwrap_or_else(|e| panic!("{e}"))
}

fn side(raw: &str) -> CanonicalSide {
    side_with(raw, None, &facts())
}

fn id(a: &CanonicalSide, b: &CanonicalSide) -> EntryId {
    EntryId::for_pair(a, b)
}

#[test]
fn the_same_pair_in_either_order_has_one_id() {
    let (a, b) = (side("/home/me/notes"), side("me@phone:/sdcard/notes"));
    assert_eq!(id(&a, &b), id(&b, &a));
    // Positive control: a different pair has a different id.
    assert_ne!(id(&a, &b), id(&a, &side("me@phone:/sdcard/other")));
}

#[test]
fn a_renamed_peer_keeps_the_id_and_a_new_key_changes_it() {
    let local = side("/home/me/notes");
    let key = device(b"phone key");
    let before = side_with("peer://phone:/sdcard/notes", Some(key), &facts());
    let renamed = side_with("peer://pixel:/sdcard/notes", Some(key), &facts());
    let repaired = side_with(
        "peer://phone:/sdcard/notes",
        Some(device(b"new key")),
        &facts(),
    );
    assert_eq!(id(&local, &before), id(&local, &renamed));
    assert_ne!(id(&local, &before), id(&local, &repaired));
}

#[test]
fn a_named_profile_and_an_ad_hoc_run_over_the_same_pair_agree() {
    let profile = crate::profile::Profile::parse(
        "[replicas]\n\
         a = \"peer://phone:/sdcard/notes\"\n\
         a_device_id = \"e3b0:c442:98fc:1c14:9afb:f4c8:996f:b924:27ae:41e4:649b:934c:a495:991b:7852:b855\"\n\
         b = \"~/notes\"\n\
         [rules]\n\
         ignore = [\"*.tmp\"]\n",
        Platform::Unix,
    )
    .unwrap_or_else(|e| panic!("{e}"));
    // The ad-hoc run: typed in the other order, from the home directory,
    // relative; the peer name resolved through the store to the same id.
    let ad_hoc = id(
        &side_with("notes", None, &facts_in(HOME)),
        &side_with("peer://phone:/sdcard/notes/", Some(device(b"")), &facts()),
    );
    assert_eq!(profile.id(&facts()), Ok(ad_hoc));
}

#[test]
fn an_ssh_side_is_the_same_tree_however_it_is_reached() {
    let local = side("/a");
    assert_eq!(
        id(&local, &side("phone:/notes")),
        id(&local, &side("ssh://phone:/notes/"))
    );
    assert_ne!(
        id(&local, &side("phone:/notes")),
        id(&local, &side("me@phone:/notes"))
    );
}

#[test]
fn a_relative_local_path_resolves_against_the_working_directory() {
    let remote = side("phone:/n");
    let in_proj1 = side_with("notes", None, &facts_in("/home/me/proj1"));
    let in_proj2 = side_with("notes", None, &facts_in("/home/me/proj2/"));
    let absolute = side("/home/me/proj1/notes");
    assert_eq!(id(&in_proj1, &remote), id(&absolute, &remote));
    assert_ne!(id(&in_proj1, &remote), id(&in_proj2, &remote));
}

#[test]
fn home_and_variables_expand_on_a_local_side_only() {
    assert_eq!(side("~/notes"), side("/home/me/notes/"));
    assert_eq!(side("$DATA/x"), side("/srv/data/x"));
    assert_eq!(side("${DATA}/x"), side("/srv/data/x"));
    assert_eq!(side("$NOPE/x").to_string(), "/work/$NOPE/x");
    // A remote `~` resolves on the far side, so it is kept as typed.
    assert_eq!(side("phone:~/notes").to_string(), "phone:~/notes");
    assert_ne!(side("phone:~/notes"), side("phone:/home/me/notes"));
}

#[test]
fn a_local_tilde_without_a_home_is_an_error() {
    let homeless = HostFacts::new(Platform::Unix, None, [], "/w".to_owned());
    assert!(CanonicalSide::of(&replica("~/notes", None), &homeless).is_err());
    assert!(CanonicalSide::of(&replica("notes", None), &homeless).is_ok());
}

#[test]
fn windows_paths_resolve_with_windows_rules() {
    let windows = HostFacts::new(Platform::Windows, None, [], "C:\\Users\\me".to_owned());
    let resolve = |raw: &str| {
        let location = Location::parse(raw, Platform::Windows).unwrap_or_else(|e| panic!("{e}"));
        let replica = ReplicaLocation::new(location, None).unwrap_or_else(|e| panic!("{e}"));
        CanonicalSide::of(&replica, &windows)
            .unwrap_or_else(|e| panic!("{e}"))
            .to_string()
    };
    assert_eq!(resolve("notes"), "C:\\Users\\me\\notes");
    assert_eq!(resolve("C:\\Users\\me\\notes\\"), "C:\\Users\\me\\notes");
    assert_eq!(resolve("D:/data"), "D:/data");
}

#[test]
fn local_unix_and_peer_sides_never_collide() {
    let peer = side_with("peer://x:/p", Some(device(b"k")), &facts());
    let sides = [side("/p"), side("x:/p"), side("unix:///x:/p"), peer];
    for (i, a) in sides.iter().enumerate() {
        for b in &sides[i + 1..] {
            assert_ne!(a.encode(), b.encode(), "{a} vs {b}");
        }
    }
}

#[test]
fn for_pair_pins_a_known_vector() {
    // Pinned before the ProfileId -> EntryId rename (Phase 1 of the
    // multi-entry-profiles plan) to prove the derivation itself did not
    // change; Phase 2 relies on this same value for a folder entry's id.
    let pinned = id(&side("/a"), &side("/b"));
    assert_eq!(pinned.as_str(), "424ee6fb554b2977c1a940c91cb7c5b8");
}

#[test]
fn the_id_is_32_lowercase_hex_and_reads_back() {
    let entry_id = id(&side("/a"), &side("/b"));
    assert_eq!(entry_id.as_str().len(), 32);
    assert_eq!(EntryId::parse(entry_id.as_str()), Ok(entry_id.clone()));
    for bad in ["", "ABCDEF0123456789ABCDEF0123456789", "../x", "notes"] {
        assert!(EntryId::parse(bad).is_err(), "{bad}");
    }
}
