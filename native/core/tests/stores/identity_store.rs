//! The cases of `test/dsync_core/identity/device_identity_store_test.dart`,
//! plus the owner-only key and the Dart-era identity refusal.

use std::fs;
use std::time::{Duration, SystemTime};

use dsync_core::atomic_write::{FileAccess, write_atomically_with};
use dsync_core::{DeviceIdentityStore, IdentityError, StateDir};
use dsync_domain::{DirRule, HostFacts, Platform, StateDirChoice};

use crate::support::names_in;

fn now() -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_790_000_000)
}

fn store_in(dir: &std::path::Path) -> DeviceIdentityStore {
    DeviceIdentityStore::new(&StateDir::new(dir))
}

#[test]
fn a_freshly_generated_identity_loads_back_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let store = store_in(dir.path());
    assert!(store.load().unwrap().is_none());

    let created = store.load_or_create("dsync-test", now()).unwrap();
    let loaded = store_in(dir.path()).load().unwrap().unwrap();

    assert_eq!(loaded, created);
    assert_eq!(loaded.device_id(), created.device_id());
    assert_eq!(names_in(dir.path()), ["identity.crt", "identity.key"]);
}

#[test]
fn a_second_run_reuses_rather_than_regenerates() {
    let dir = tempfile::tempdir().unwrap();
    let first = store_in(dir.path()).load_or_create("first", now()).unwrap();
    let second = store_in(dir.path())
        .load_or_create("second", now() + Duration::from_secs(60))
        .unwrap();
    assert_eq!(second, first);
    assert_eq!(second.certificate().common_name(), Some("first"));
}

#[test]
fn creates_the_state_directory_when_it_does_not_exist_yet() {
    let dir = tempfile::tempdir().unwrap();
    let nested = dir.path().join("nested/state");
    store_in(&nested)
        .load_or_create("dsync-test", now())
        .unwrap();
    assert_eq!(names_in(&nested), ["identity.crt", "identity.key"]);
}

#[test]
fn the_files_are_pem() {
    let dir = tempfile::tempdir().unwrap();
    store_in(dir.path())
        .load_or_create("dsync-test", now())
        .unwrap();
    let certificate = fs::read_to_string(dir.path().join("identity.crt")).unwrap();
    let key = fs::read_to_string(dir.path().join("identity.key")).unwrap();
    assert!(certificate.starts_with("-----BEGIN CERTIFICATE-----\n"));
    assert!(key.starts_with("-----BEGIN PRIVATE KEY-----\n"));
}

#[cfg(unix)]
#[test]
fn the_private_key_is_owner_read_write_only() {
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().unwrap();
    store_in(dir.path())
        .load_or_create("dsync-test", now())
        .unwrap();
    let mode = |name: &str| {
        fs::metadata(dir.path().join(name))
            .unwrap()
            .permissions()
            .mode()
            & 0o777
    };
    assert_eq!(mode("identity.key"), 0o600);
    // Positive control: the public certificate gets an ordinary mode, so
    // the 0600 above is the store's doing, not the temp dir's umask.
    assert_ne!(mode("identity.crt"), 0o600);
}

/// The temp the key is staged in is 0600 from its creation, before any
/// byte of the key is written, and whatever the umask would allow.
#[cfg(unix)]
#[test]
fn an_owner_only_temp_is_created_owner_only() {
    use dsync_core::atomic_write::stage_with;
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("identity.key");
    let staged = stage_with(&target, b"secret", FileAccess::OwnerOnly).unwrap();
    let mode = fs::metadata(staged.temp_path())
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600);
    staged.commit().unwrap();

    // A replacement over a looser file leaves it owner-only too.
    fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap();
    write_atomically_with(&target, b"again", FileAccess::OwnerOnly).unwrap();
    let mode = fs::metadata(&target).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
}

#[test]
fn only_the_certificate_half_is_refused_as_incomplete() {
    let dir = tempfile::tempdir().unwrap();
    store_in(dir.path())
        .load_or_create("dsync-test", now())
        .unwrap();
    fs::remove_file(dir.path().join("identity.key")).unwrap();

    let error = store_in(dir.path())
        .load_or_create("dsync-test", now())
        .unwrap_err();
    assert!(
        matches!(&error, IdentityError::Incomplete { present, .. } if present.ends_with("identity.crt")),
        "{error:?}"
    );
    assert!(error.to_string().contains("Delete"), "{error}");
    // Nothing was regenerated over the surviving half.
    assert_eq!(names_in(dir.path()), ["identity.crt"]);
}

#[test]
fn only_the_private_key_half_is_refused_as_incomplete() {
    let dir = tempfile::tempdir().unwrap();
    store_in(dir.path())
        .load_or_create("dsync-test", now())
        .unwrap();
    fs::remove_file(dir.path().join("identity.crt")).unwrap();

    let error = store_in(dir.path()).load().unwrap_err();
    assert!(
        matches!(&error, IdentityError::Incomplete { present, .. } if present.ends_with("identity.key")),
        "{error:?}"
    );
}

#[test]
fn a_key_that_is_not_the_certificates_is_refused_naming_both_files() {
    let (one, two) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    store_in(one.path()).load_or_create("one", now()).unwrap();
    store_in(two.path()).load_or_create("two", now()).unwrap();
    fs::copy(
        two.path().join("identity.key"),
        one.path().join("identity.key"),
    )
    .unwrap();

    let error = store_in(one.path()).load().unwrap_err();
    assert!(matches!(error, IdentityError::Corrupt { .. }), "{error:?}");
    let message = error.to_string();
    assert!(
        message.contains("identity.crt") && message.contains("identity.key"),
        "{message}"
    );

    fs::write(one.path().join("identity.crt"), "not pem").unwrap();
    assert!(matches!(
        store_in(one.path()).load(),
        Err(IdentityError::Corrupt { .. })
    ));
}

/// The Dart identity was a CA certificate. Written by hand here with
/// rcgen, `cA:TRUE`, as the Dart generator would have.
#[test]
fn a_dart_era_ca_identity_is_refused_naming_the_files_to_delete() {
    use rcgen::{BasicConstraints, CertificateParams, IsCa, KeyPair};

    let dir = tempfile::tempdir().unwrap();
    let key = KeyPair::generate().unwrap();
    let mut params = CertificateParams::new(Vec::<String>::new()).unwrap();
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let certificate = params.self_signed(&key).unwrap();
    fs::write(dir.path().join("identity.crt"), certificate.pem()).unwrap();
    fs::write(dir.path().join("identity.key"), key.serialize_pem()).unwrap();

    let error = store_in(dir.path()).load().unwrap_err();
    assert!(
        matches!(error, IdentityError::ForeignSchema { .. }),
        "{error:?}"
    );
    assert!(error.to_string().contains("Delete"), "{error}");
}

#[test]
fn renewal_rewrites_the_certificate_under_the_same_key_and_id_in_place() {
    let dir = tempfile::tempdir().unwrap();
    let store = store_in(dir.path());
    let original = store.load_or_create("dsync-test", now()).unwrap();
    let key_before = fs::read(dir.path().join("identity.key")).unwrap();

    let later = now() + Duration::from_secs(400 * 24 * 60 * 60);
    let renewed = store.renew(None, later).unwrap();
    let reloaded = store.load().unwrap().unwrap();

    assert_eq!(renewed.device_id(), original.device_id());
    assert_eq!(reloaded, renewed);
    assert_ne!(reloaded.certificate(), original.certificate());
    assert!(
        reloaded.certificate().validity().not_after()
            > original.certificate().validity().not_after()
    );
    assert_eq!(
        fs::read(dir.path().join("identity.key")).unwrap(),
        key_before
    );
    assert_eq!(names_in(dir.path()), ["identity.crt", "identity.key"]);
}

#[test]
fn a_common_name_renames_the_device_in_place_keeping_its_id() {
    let dir = tempfile::tempdir().unwrap();
    let store = store_in(dir.path());
    let original = store.load_or_create("studio", now()).unwrap();

    let renamed = store.renew(Some("workshop"), now()).unwrap();

    let reloaded = store.load().unwrap().unwrap();
    assert_eq!(reloaded.certificate().common_name(), Some("workshop"));
    assert_eq!(renamed.device_id(), original.device_id());
    assert_eq!(reloaded.key_pkcs8_der(), original.key_pkcs8_der());
}

#[test]
fn renewal_refuses_when_there_is_no_identity_or_only_half_of_one() {
    let dir = tempfile::tempdir().unwrap();
    let store = store_in(dir.path());
    assert!(matches!(
        store.renew(None, now()),
        Err(IdentityError::Missing { .. })
    ));
    // Renewal never creates one.
    assert!(names_in(dir.path()).is_empty());

    fs::write(dir.path().join("identity.key"), "half").unwrap();
    assert!(matches!(
        store.renew(None, now()),
        Err(IdentityError::Incomplete { .. })
    ));
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
    let store = DeviceIdentityStore::new(&state);
    assert_eq!(
        store.certificate_path(),
        state_home.join("dsync-rs/identity.crt")
    );
    assert_eq!(store.key_path(), state_home.join("dsync-rs/identity.key"));
}
