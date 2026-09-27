//! `dsync pair list | revoke | grant | renew`, and the argument refusals of
//! every `pair` subcommand, through the binary: the cases of the Dart
//! `pair_command_test`, `pair_list_command_test`, `pair_grant_command_test`,
//! `pair_revoke_command_test`, `pair_renew_command_test` and
//! `pair_accept_command_test`.

use std::time::{Duration, SystemTime};

use dsync_core::{DeviceIdentityStore, StateDir};
use dsync_domain::CertificateValidity;
use serde_json::Value;

use crate::support::{Site, paired, seed_device};

const DAY: Duration = Duration::from_secs(24 * 60 * 60);

fn now() -> SystemTime {
    SystemTime::now()
}

#[test]
fn pair_with_no_subcommand_or_an_unknown_one_exits_3() {
    let site = Site::new();
    let bare = site.run(&["pair"]);
    bare.exits(3);
    assert!(bare.stderr.contains("show"), "{bare:#?}");
    site.run(&["pair", "frobnicate"]).exits(3);
}

#[test]
fn every_pair_subcommand_is_reachable() {
    let site = Site::new();
    let help = site.run(&["pair", "--help"]);
    help.exits(0);
    for command in ["show", "accept", "list", "revoke", "grant", "renew"] {
        assert!(help.stdout.contains(command), "{command}: {help:#?}");
    }
    site.run(&["pair", "list"]).exits(0);
}

#[test]
fn an_empty_store_lists_as_no_paired_devices_with_nothing_on_stderr() {
    let site = Site::new();
    let listed = site.run(&["pair", "list"]);
    listed.exits(0);
    assert_eq!(listed.stdout, "No paired devices.\n");
    assert_eq!(listed.stderr, "");
    assert!(
        !site.state_dir().join("identity.crt").exists(),
        "listing minted an identity"
    );
}

#[test]
fn a_listing_names_each_device_its_id_address_and_roots() {
    let site = Site::new();
    let device = seed_device(&site.state_dir(), "phone", &["/home/me/notes"], now());
    let listed = site.run(&["pair", "list"]);
    listed.exits(0);
    assert!(listed.stdout.starts_with("phone  "), "{listed:#?}");
    assert!(listed.stdout.contains(&device.device_id().to_string()));
    assert!(listed.stdout.contains("192.168.1.5:28771"));
    assert!(listed.stdout.contains("/home/me/notes"));
}

#[test]
fn json_lists_one_decodable_object_per_device() {
    let site = Site::new();
    seed_device(&site.state_dir(), "phone", &["/home/me/notes"], now());
    seed_device(&site.state_dir(), "laptop", &[], now());
    let listed = site.run(&["pair", "list", "--json"]);
    listed.exits(0);
    let lines: Vec<Value> = listed
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    assert!(lines.iter().all(|line| line["type"] == "pairedDevice"));
    let named = |name: &str| lines.iter().find(|line| line["name"] == name).unwrap();
    assert_eq!(
        named("phone")["agreedReplicaRoots"],
        serde_json::json!(["/home/me/notes"])
    );
    assert_eq!(
        named("phone")["lastKnownAddress"],
        serde_json::json!({"host": "192.168.1.5", "port": 28771})
    );
    assert_eq!(named("laptop")["agreedReplicaRoots"], serde_json::json!([]));
}

#[test]
fn list_takes_no_positional_argument() {
    Site::new().run(&["pair", "list", "bogus"]).exits(3);
}

#[test]
fn expiry_warnings_go_to_stderr_in_both_modes_and_only_for_certificates_near_it() {
    let site = Site::new();
    // Issued so that it expired a little over two days ago.
    let lifetime = CertificateValidity::LIFETIME - CertificateValidity::BACKDATE;
    let expired_issue = now() - lifetime - 2 * DAY - Duration::from_secs(60);
    seed_device(&site.state_dir(), "phone", &[], expired_issue);
    seed_device(&site.state_dir(), "laptop", &[], now());
    DeviceIdentityStore::new(&StateDir::new(site.state_dir()))
        .load_or_create("host", now())
        .unwrap();
    for args in [&["pair", "list"][..], &["pair", "list", "--json"]] {
        let listed = site.run(args);
        listed.exits(0);
        assert!(
            listed
                .stderr
                .contains("warning: certificate for phone expired 2 days ago"),
            "{listed:#?}"
        );
        assert!(!listed.stderr.contains("laptop"), "{listed:#?}");
        assert!(!listed.stderr.contains("this host"), "{listed:#?}");
        assert!(!listed.stdout.contains("certificate for"), "{listed:#?}");
    }
}

#[test]
fn a_grant_is_stored_and_survives_without_disturbing_the_pairing() {
    let site = Site::new();
    let device = seed_device(&site.state_dir(), "phone", &[], now());
    let granted = site.run(&["pair", "grant", "phone", "/home/me/notes"]);
    granted.exits(0);
    assert!(granted.stdout.contains("/home/me/notes"), "{granted:#?}");
    let devices = paired(&site.state_dir());
    let stored = devices.get(&device.device_id()).unwrap();
    assert_eq!(devices.len(), 1);
    assert!(stored.serves_root("/home/me/notes"));
    assert_eq!(stored.paired_at(), device.paired_at());
    assert_eq!(stored.name(), device.name());
}

#[test]
fn a_grant_expands_a_leading_tilde_against_home_as_a_peer_root_is() {
    let site = Site::new();
    seed_device(&site.state_dir(), "phone", &[], now());
    site.run(&["pair", "grant", "phone", "~/notes"]).exits(0);
    let devices = paired(&site.state_dir());
    let roots: Vec<_> = devices
        .iter()
        .next()
        .unwrap()
        .granted_roots()
        .iter()
        .cloned()
        .collect();
    assert_eq!(roots, [site.arg("notes")]);
}

#[test]
fn granting_or_revoking_an_unpaired_name_changes_nothing_and_exits_3() {
    let site = Site::new();
    seed_device(&site.state_dir(), "phone", &[], now());
    let before = std::fs::read(site.state_dir().join("paired-devices.json")).unwrap();
    for args in [
        &["pair", "grant", "not-a-real-name", "/home/me/notes"][..],
        &["pair", "revoke", "not-a-real-name"],
    ] {
        let refused = site.run(args);
        refused.exits(3);
        assert!(
            refused
                .stderr
                .contains("no paired device named \"not-a-real-name\""),
            "{refused:#?}"
        );
    }
    let after = std::fs::read(site.state_dir().join("paired-devices.json")).unwrap();
    assert_eq!(before, after);
}

#[test]
fn a_root_already_granted_is_not_duplicated() {
    let site = Site::new();
    seed_device(&site.state_dir(), "phone", &["/home/me/notes"], now());
    site.run(&["pair", "grant", "phone", "/home/me/notes"])
        .exits(0);
    let devices = paired(&site.state_dir());
    assert_eq!(devices.iter().next().unwrap().granted_roots().len(), 1);
}

#[test]
fn a_grant_nesting_with_one_already_granted_is_refused_naming_it_and_exits_3() {
    let site = Site::new();
    seed_device(
        &site.state_dir(),
        "phone",
        &["/home/me/notes", "/home/me/todo.txt"],
        now(),
    );
    let before = std::fs::read(site.state_dir().join("paired-devices.json")).unwrap();
    for (root, existing) in [
        ("/home/me/notes/2026", "/home/me/notes"),
        ("/home/me/notes/list.txt", "/home/me/notes"),
        ("/home/me", "/home/me/notes"),
    ] {
        let refused = site.run(&["pair", "grant", "phone", root]);
        refused.exits(3);
        assert!(
            refused
                .stderr
                .contains(&format!("cannot grant {root}: it overlaps {existing}")),
            "{refused:#?}"
        );
    }
    let after = std::fs::read(site.state_dir().join("paired-devices.json")).unwrap();
    assert_eq!(before, after);
    // Positive control: a sibling sharing only a prefix of characters.
    site.run(&["pair", "grant", "phone", "/home/me/notesx"])
        .exits(0);
}

#[test]
fn grant_needs_exactly_two_arguments_and_revoke_one() {
    let site = Site::new();
    for args in [
        &["pair", "grant", "phone"][..],
        &["pair", "grant"],
        &["pair", "grant", "phone", "/a", "/b"],
        &["pair", "revoke"],
        &["pair", "revoke", "a", "b"],
    ] {
        site.run(args).exits(3);
    }
}

#[test]
fn revoking_a_paired_name_removes_it() {
    let site = Site::new();
    let device = seed_device(&site.state_dir(), "phone", &[], now());
    let revoked = site.run(&["pair", "revoke", "phone"]);
    revoked.exits(0);
    assert!(revoked.stdout.contains("phone"), "{revoked:#?}");
    assert!(
        revoked.stdout.contains(&device.device_id().to_string()),
        "{revoked:#?}"
    );
    assert!(paired(&site.state_dir()).is_empty());
}

#[test]
fn renew_keeps_the_device_id_and_replaces_the_certificate() {
    let site = Site::new();
    let store = DeviceIdentityStore::new(&StateDir::new(site.state_dir()));
    let before = store.load_or_create("host", now()).unwrap();
    let renewed = site.run(&["pair", "renew"]);
    renewed.exits(0);
    assert!(
        renewed.stdout.contains(&before.device_id().to_string()),
        "{renewed:#?}"
    );
    assert_eq!(renewed.stderr, "");
    let after = store.load().unwrap().unwrap();
    assert_eq!(after.device_id(), before.device_id());
    assert_ne!(after.certificate().der(), before.certificate().der());
}

#[test]
fn renew_mints_a_missing_identity_but_refuses_a_half_written_one() {
    let site = Site::new();
    site.run(&["pair", "renew"]).exits(0);
    std::fs::remove_file(site.state_dir().join("identity.key")).unwrap();
    let refused = site.run(&["pair", "renew"]);
    refused.exits(3);
    assert!(refused.stderr.contains("incomplete"), "{refused:#?}");
}

#[test]
fn accept_refuses_a_malformed_or_unsupported_payload_by_name() {
    let site = Site::new();
    let malformed = site.run(&[
        "pair",
        "accept",
        "--name",
        "desktop",
        "not-a-pairing-payload",
    ]);
    malformed.exits(3);
    assert!(
        malformed.stderr.contains("not a dsync pairing code"),
        "{malformed:#?}"
    );
    let newer = site.run(&[
        "pair",
        "accept",
        "--name",
        "desktop",
        "dsync-pair:99.0:AAAA",
    ]);
    newer.exits(3);
    assert!(
        newer.stderr.contains("from a newer dsync (format 99.0"),
        "{newer:#?}"
    );
    assert!(
        !site.state_dir().exists(),
        "a refused accept left state behind"
    );
}

#[test]
fn accept_needs_a_name_and_exactly_one_payload() {
    let site = Site::new();
    site.run(&["pair", "accept", "dsync-pair:1.0:AAAA"])
        .exits(3);
    site.run(&["pair", "accept", "--name", "  ", "dsync-pair:1.0:AAAA"])
        .exits(3);
    site.run(&["pair", "accept", "--name", "desktop"]).exits(3);
    site.run(&["pair", "accept", "--name", "desktop", "a", "b"])
        .exits(3);
}
