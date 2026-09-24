//! The cases of `test/dsync_core/identity/paired_device_store_test.dart`
//! against a real file: absent vs. damaged, round trips, every change
//! surviving a reload, freshness across instances, and the Dart-era
//! document refused by name.

use std::fs;
use std::time::{Duration, SystemTime};

use dsync_core::{
    DeviceIdentity, PairedDevice, PairedDeviceStore, PairedDeviceStoreError, PairedDevices,
    PairingError, StateDir,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{DeviceId, DirRule, HostFacts, PeerName, Platform, StateDirChoice};
use tempfile::TempDir;

fn at(seconds: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(seconds)
}

fn identity() -> DeviceIdentity {
    DeviceIdentity::generate("peer", at(1_790_000_000)).unwrap()
}

fn name(text: &str) -> PeerName {
    PeerName::parse(text).unwrap()
}

fn address(host: &str, port: u16) -> PeerAddress {
    PeerAddress::new(host, port).unwrap()
}

fn device(identity: &DeviceIdentity, label: &str) -> PairedDevice {
    PairedDevice::new(
        identity.certificate().clone(),
        name(label),
        address("192.168.1.5", 28771),
        at(1_790_000_000),
    )
}

struct Fixture {
    dir: TempDir,
}

impl Fixture {
    fn new() -> Fixture {
        Fixture {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    /// A fresh store instance every call: nothing may be cached between
    /// them.
    fn store(&self) -> PairedDeviceStore {
        PairedDeviceStore::new(&StateDir::new(self.dir.path()))
    }

    fn write(&self, text: &str) {
        fs::write(self.store().path(), text).unwrap();
    }

    fn load(&self) -> PairedDevices {
        self.store().load().unwrap()
    }

    fn add(&self, device: PairedDevice) {
        self.store().update(|devices| devices.add(device)).unwrap();
    }
}

fn corrupt_detail(fixture: &Fixture) -> String {
    match fixture.store().load() {
        Err(error @ PairedDeviceStoreError::Corrupt { .. }) => {
            let message = error.to_string();
            assert!(
                message.contains(&fixture.store().path().display().to_string()),
                "{message}"
            );
            message
        }
        other => panic!("expected corruption, got {other:?}"),
    }
}

// load - absent vs. damaged

#[test]
fn a_missing_file_is_an_empty_set_not_an_error() {
    let fixture = Fixture::new();
    assert!(fixture.load().is_empty());
}

#[test]
fn a_damaged_file_is_corruption_not_an_empty_set() {
    let fixture = Fixture::new();
    for text in [
        "",
        "{\"schemaVersion\": 2, \"devi",
        "{not json at all",
        "[]",
        "{\"totally\": \"unrelated\"}",
        "{\"schemaVersion\": \"2\", \"devices\": {}}",
        "{\"schemaVersion\": 2, \"devices\": []}",
        "{\"schemaVersion\": 2, \"devices\": {}, \"extra\": 1}",
    ] {
        fixture.write(text);
        corrupt_detail(&fixture);
    }
}

#[test]
fn a_device_entry_missing_a_field_or_with_a_bad_one_is_corruption() {
    let fixture = Fixture::new();
    let phone = identity();
    fixture.add(device(&phone, "phone"));
    let good = fs::read_to_string(fixture.store().path()).unwrap();
    // Positive control: the file as written loads.
    assert_eq!(fixture.load().len(), 1);

    let edits: [(&str, &str); 6] = [
        ("\"name\": \"phone\",", ""),
        ("\"name\": \"phone\"", "\"name\": \"a:b\""),
        ("\"port\": 28771", "\"port\": 0"),
        ("\"pairedAt\": \"", "\"pairedAt\": \"yesterday "),
        ("-----BEGIN CERTIFICATE-----", "-----BEGIN KEY-----"),
        ("\"grantedRoots\": []", "\"grantedRoots\": {}"),
    ];
    for (from, to) in edits {
        assert!(good.contains(from), "{from} not in {good}");
        fixture.write(&good.replacen(from, to, 1));
        corrupt_detail(&fixture);
    }
    // A malformed confirmation is corruption, not an absent one.
    fixture.write(&good.replacen("\"name\"", "\"verifiedAt\": \"yes\",\n    \"name\"", 1));
    corrupt_detail(&fixture);
}

#[test]
fn an_entry_filed_under_another_devices_id_is_corruption() {
    let fixture = Fixture::new();
    let (phone, other) = (identity(), identity());
    fixture.add(device(&phone, "phone"));
    let good = fs::read_to_string(fixture.store().path()).unwrap();
    fixture.write(&good.replace(
        &phone.device_id().to_string(),
        &other.device_id().to_string(),
    ));
    let message = corrupt_detail(&fixture);
    assert!(message.contains("its certificate is device"), "{message}");
}

#[test]
fn two_entries_under_one_name_are_corruption() {
    let fixture = Fixture::new();
    fixture.add(device(&identity(), "phone"));
    fixture.add(device(&identity(), "laptop"));
    let good = fs::read_to_string(fixture.store().path()).unwrap();
    fixture.write(&good.replace("\"laptop\"", "\"phone\""));
    corrupt_detail(&fixture);
}

#[test]
fn a_well_formed_document_with_zero_devices_is_a_legitimate_empty_set() {
    let fixture = Fixture::new();
    fixture.write("{\"schemaVersion\": 2, \"devices\": {}}");
    assert!(fixture.load().is_empty());
}

/// Byte-for-byte the shape the Dart store wrote (schema 1).
#[test]
fn a_dart_era_document_is_refused_naming_the_file_and_saying_to_delete_it() {
    let fixture = Fixture::new();
    let certificate = identity().certificate().to_pem().replace('\n', "\\n");
    fixture.write(&format!(
        r#"{{"schemaVersion":1,"devices":[{{"certificatePem":"{certificate}","name":"phone","agreedReplicaRoots":["/home/me/notes"],"pairedAt":"2026-09-15T11:21:00.000Z","lastKnownAddress":{{"host":"192.168.1.5","port":28771}}}}]}}"#
    ));

    let error = fixture.store().load().unwrap_err();
    assert!(
        matches!(&error, PairedDeviceStoreError::ForeignSchema { found, .. } if found == "1"),
        "{error:?}"
    );
    let message = error.to_string();
    let path = fixture.store().path().display().to_string();
    assert!(message.contains(&format!("Delete {path}")), "{message}");

    // So is any other schema; and a change is refused without writing.
    fixture.write("{\"schemaVersion\": 999, \"devices\": []}");
    assert!(matches!(
        fixture
            .store()
            .update(|devices| devices.add(device(&identity(), "x"))),
        Err(PairedDeviceStoreError::ForeignSchema { .. })
    ));
    assert_eq!(
        fs::read_to_string(fixture.store().path()).unwrap(),
        "{\"schemaVersion\": 999, \"devices\": []}"
    );
}

// add / round trip

#[test]
fn devices_round_trip_through_add_and_a_fresh_load() {
    let fixture = Fixture::new();
    let (phone, laptop) = (identity(), identity());
    let mut first = device(&phone, "phone");
    first.grant("/home/me/notes".to_owned());
    fixture.add(first.clone());
    fixture.add(device(&laptop, "laptop"));

    let reloaded = fixture.load();
    assert_eq!(reloaded.len(), 2);
    assert_eq!(reloaded.get(&phone.device_id()), Some(&first));
    assert_eq!(
        reloaded.get(&laptop.device_id()),
        Some(&device(&laptop, "laptop"))
    );
}

#[test]
fn a_name_or_device_id_collision_is_refused_and_nothing_is_written() {
    let fixture = Fixture::new();
    let phone = identity();
    fixture.add(device(&phone, "phone"));
    let before = fs::read(fixture.store().path()).unwrap();

    let name_clash = fixture
        .store()
        .update(|devices| devices.add(device(&identity(), "phone")));
    assert!(matches!(
        name_clash,
        Err(PairedDeviceStoreError::Pairing(PairingError::NameTaken(_)))
    ));
    let id_clash = fixture
        .store()
        .update(|devices| devices.add(device(&phone, "laptop")));
    assert!(matches!(
        id_clash,
        Err(PairedDeviceStoreError::Pairing(
            PairingError::AlreadyPaired { .. }
        ))
    ));
    assert_eq!(fs::read(fixture.store().path()).unwrap(), before);
}

// revoke

#[test]
fn revoke_removes_the_device_confirmed_by_a_reload() {
    let fixture = Fixture::new();
    let (phone, laptop) = (identity(), identity());
    fixture.add(device(&phone, "phone"));
    fixture.add(device(&laptop, "laptop"));

    fixture
        .store()
        .update(|devices| devices.revoke(&phone.device_id()))
        .unwrap();

    let reloaded = fixture.load();
    assert_eq!(reloaded.get(&phone.device_id()), None);
    assert_eq!(reloaded.len(), 1);
    assert!(reloaded.by_name(&name("laptop")).is_some());

    fixture
        .store()
        .update(|devices| devices.revoke(&laptop.device_id()))
        .unwrap();
    assert!(fixture.load().is_empty());
}

#[test]
fn revoking_an_unknown_device_id_is_refused() {
    let fixture = Fixture::new();
    fixture.add(device(&identity(), "phone"));
    let stranger = identity().device_id();
    assert!(matches!(
        fixture.store().update(|devices| devices.revoke(&stranger)),
        Err(PairedDeviceStoreError::Pairing(PairingError::NotPaired(id))) if id == stranger
    ));
}

// lookups

#[test]
fn lookups_by_id_and_by_this_hosts_name_for_it() {
    let fixture = Fixture::new();
    let phone = identity();
    fixture.add(device(&phone, "phone"));
    let devices = fixture.load();
    assert_eq!(
        devices.get(&phone.device_id()).map(|d| d.name().clone()),
        Some(name("phone"))
    );
    assert_eq!(devices.get(&identity().device_id()), None);
    assert_eq!(
        devices.by_name(&name("phone")).map(PairedDevice::device_id),
        Some(phone.device_id())
    );
    assert_eq!(devices.by_name(&name("tablet")), None);
}

// recordConnection

#[test]
fn recording_a_connection_updates_the_address_and_certificate_and_survives_a_reload() {
    let fixture = Fixture::new();
    let phone = identity();
    let mut paired = device(&phone, "phone");
    paired.grant("/a".to_owned());
    fixture.add(paired);
    let renewed = phone.renewed(None, at(1_800_000_000)).unwrap();

    fixture
        .store()
        .update(|devices| {
            devices.record_connection(
                &phone.device_id(),
                address("10.0.0.7", 30000),
                renewed.certificate().clone(),
            )
        })
        .unwrap();

    let reloaded = fixture.load();
    let recorded = reloaded.get(&phone.device_id()).unwrap();
    assert_eq!(recorded.last_known_address(), &address("10.0.0.7", 30000));
    assert_eq!(recorded.certificate(), renewed.certificate());
    assert_eq!(recorded.name(), &name("phone"));
    assert!(recorded.serves_root("/a"));
    assert_eq!(recorded.paired_at(), at(1_790_000_000));
}

#[test]
fn recording_a_connection_refuses_an_unknown_id_or_another_key() {
    let fixture = Fixture::new();
    let phone = identity();
    fixture.add(device(&phone, "phone"));
    let stranger = identity();
    let unknown = fixture.store().update(|devices| {
        devices.record_connection(
            &stranger.device_id(),
            address("h", 1),
            stranger.certificate().clone(),
        )
    });
    assert!(matches!(
        unknown,
        Err(PairedDeviceStoreError::Pairing(PairingError::NotPaired(_)))
    ));
    let other_key = fixture.store().update(|devices| {
        devices.record_connection(
            &phone.device_id(),
            address("h", 1),
            stranger.certificate().clone(),
        )
    });
    assert!(matches!(
        other_key,
        Err(PairedDeviceStoreError::Pairing(PairingError::DifferentKey(
            _
        )))
    ));
    assert_eq!(
        fixture.load().get(&phone.device_id()),
        Some(&device(&phone, "phone"))
    );
}

// grant / withdraw

#[test]
fn grants_are_additive_idempotent_and_survive_a_reload_without_touching_others() {
    let fixture = Fixture::new();
    let (phone, laptop) = (identity(), identity());
    fixture.add(device(&phone, "phone"));
    fixture.add(device(&laptop, "laptop"));
    let id = phone.device_id();

    for root in ["/home/me/notes", "/home/me/photos", "/home/me/notes"] {
        fixture
            .store()
            .update(|devices| devices.grant(&id, root.to_owned()))
            .unwrap();
    }

    let reloaded = fixture.load();
    let granted = reloaded.get(&id).unwrap();
    assert_eq!(
        granted.granted_roots().iter().collect::<Vec<_>>(),
        ["/home/me/notes", "/home/me/photos"]
    );
    assert_eq!(granted.paired_at(), at(1_790_000_000));
    assert_eq!(
        reloaded.get(&laptop.device_id()),
        Some(&device(&laptop, "laptop"))
    );
}

#[test]
fn withdrawing_takes_one_root_and_keeps_the_rest_and_a_never_granted_one_is_fine() {
    let fixture = Fixture::new();
    let phone = identity();
    let id = phone.device_id();
    fixture.add(device(&phone, "phone"));
    for root in ["/a", "/b"] {
        fixture
            .store()
            .update(|devices| devices.grant(&id, root.to_owned()))
            .unwrap();
    }

    fixture
        .store()
        .update(|devices| devices.withdraw_grant(&id, "/a"))
        .unwrap();
    fixture
        .store()
        .update(|devices| devices.withdraw_grant(&id, "/never"))
        .unwrap();

    let reloaded = fixture.load();
    let device = reloaded.get(&id).unwrap();
    assert!(!device.serves_root("/a"));
    assert!(device.serves_root("/b"));
    let stranger = identity().device_id();
    assert!(matches!(
        fixture
            .store()
            .update(|devices| devices.grant(&stranger, "/a".to_owned())),
        Err(PairedDeviceStoreError::Pairing(PairingError::NotPaired(_)))
    ));
    assert!(matches!(
        fixture
            .store()
            .update(|devices| devices.withdraw_grant(&stranger, "/a")),
        Err(PairedDeviceStoreError::Pairing(PairingError::NotPaired(_)))
    ));
}

// rename

#[test]
fn rename_relabels_the_device_and_it_is_addressable_by_the_new_name() {
    let fixture = Fixture::new();
    let (phone, laptop) = (identity(), identity());
    fixture.add(device(&phone, "phone"));
    fixture.add(device(&laptop, "laptop"));

    fixture
        .store()
        .update(|devices| devices.rename(&phone.device_id(), name("tablet")))
        .unwrap();

    let reloaded = fixture.load();
    assert_eq!(
        reloaded
            .by_name(&name("tablet"))
            .map(PairedDevice::device_id),
        Some(phone.device_id())
    );
    assert_eq!(reloaded.by_name(&name("phone")), None);

    let taken = fixture
        .store()
        .update(|devices| devices.rename(&phone.device_id(), name("laptop")));
    assert!(matches!(
        taken,
        Err(PairedDeviceStoreError::Pairing(PairingError::NameTaken(_)))
    ));
    fixture
        .store()
        .update(|devices| devices.rename(&phone.device_id(), name("tablet")))
        .unwrap();
}

// verification

#[test]
fn a_confirmation_is_recorded_survives_a_reload_and_can_be_cleared() {
    let fixture = Fixture::new();
    let (phone, laptop) = (identity(), identity());
    fixture.add(device(&phone, "phone"));
    fixture.add(device(&laptop, "laptop"));
    let id = phone.device_id();

    fixture
        .store()
        .update(|devices| devices.verify(&id, at(1_790_500_000)))
        .unwrap();
    assert_eq!(
        fixture.load().get(&id).unwrap().verified_at(),
        Some(at(1_790_500_000))
    );
    assert_eq!(
        fixture
            .load()
            .get(&laptop.device_id())
            .unwrap()
            .verified_at(),
        None
    );

    fixture
        .store()
        .update(|devices| devices.clear_verification(&id))
        .unwrap();
    assert_eq!(fixture.load().get(&id).unwrap().verified_at(), None);
    // Clearing one never made is not an error.
    fixture
        .store()
        .update(|devices| devices.clear_verification(&id))
        .unwrap();
}

#[test]
fn a_pairing_redone_from_scratch_does_not_inherit_a_confirmation() {
    let fixture = Fixture::new();
    let phone = identity();
    fixture.add(device(&phone, "phone"));
    fixture
        .store()
        .update(|devices| devices.verify(&phone.device_id(), at(5)))
        .unwrap();

    // The phone was wiped and paired again: same name here, new key.
    fixture
        .store()
        .update(|devices| devices.revoke(&phone.device_id()))
        .unwrap();
    fixture.add(device(&identity(), "phone"));

    let devices = fixture.load();
    assert_eq!(devices.iter().next().unwrap().verified_at(), None);
}

#[test]
fn an_unverified_pairing_writes_no_verification_key_at_all() {
    let fixture = Fixture::new();
    let phone = identity();
    fixture.add(device(&phone, "phone"));
    let text = fs::read_to_string(fixture.store().path()).unwrap();
    assert!(!text.contains("verifiedAt"), "{text}");
    // Positive control.
    fixture
        .store()
        .update(|devices| devices.verify(&phone.device_id(), at(5)))
        .unwrap();
    let text = fs::read_to_string(fixture.store().path()).unwrap();
    assert!(text.contains("verifiedAt"), "{text}");
}

// freshness and layout

#[test]
fn a_revocation_by_a_second_instance_is_visible_to_the_first() {
    let fixture = Fixture::new();
    let phone = identity();
    let listener_side = fixture.store();
    listener_side
        .update(|devices| devices.add(device(&phone, "phone")))
        .unwrap();
    assert!(
        listener_side
            .load()
            .unwrap()
            .get(&phone.device_id())
            .is_some()
    );

    fixture
        .store()
        .update(|devices| devices.revoke(&phone.device_id()))
        .unwrap();

    assert!(
        listener_side
            .load()
            .unwrap()
            .get(&phone.device_id())
            .is_none()
    );
}

#[test]
fn the_document_is_keyed_by_device_id_and_leaves_no_temp() {
    let fixture = Fixture::new();
    let phone = identity();
    fixture.add(device(&phone, "phone"));
    let text = fs::read_to_string(fixture.store().path()).unwrap();
    let json: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(json["schemaVersion"], 2);
    let entry = &json["devices"][phone.device_id().to_string()];
    assert_eq!(entry["name"], "phone");
    assert_eq!(entry["lastKnownAddress"]["port"], 28771);
    assert!(DeviceId::parse(&phone.device_id().to_string()).is_ok());
    assert_eq!(
        crate::support::names_in(fixture.dir.path()),
        ["paired-devices.json"]
    );
}

#[test]
fn resolves_the_standard_path_under_xdg_state_home() {
    let home = tempfile::tempdir().unwrap();
    let state_home = home.path().join("state");
    let host = HostFacts::new(
        Platform::Unix,
        Some(home.path().display().to_string()),
        [(
            "XDG_STATE_HOME".to_owned(),
            state_home.display().to_string(),
        )],
        "/".into(),
    );
    let state = StateDir::resolve(&StateDirChoice::Rule(DirRule::Xdg), &host).unwrap();
    assert_eq!(
        PairedDeviceStore::new(&state).path(),
        state_home.join("dsync/paired-devices.json")
    );
}
