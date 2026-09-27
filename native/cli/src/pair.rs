//! `dsync pair` (SPEC §4.4, §11.1): pairing over the enrolment exchange
//! (`show`, `accept`), and the paired-device store - the security
//! boundary's data - read (`list`) and changed (`revoke`, `grant`), plus
//! this host's own certificate (`renew`). Every change goes through
//! [`PairedDeviceStore::update`], one atomic write each.
//!
//! Human output goes to stdout and failures to stderr, as the Dart CLI's
//! did; `show` keeps stdout for the payload line alone.

mod accept;
mod show;

use std::io::{self, Write};
use std::time::SystemTime;

use dsync_core::{
    DeviceIdentityStore, PairedDevice, PairedDeviceStore, PairedDevices, StateDir, resolve_grant,
};
use dsync_domain::{
    CertificateExpiry, CertificateOwner, DeviceId, Location, PeerName, PeerNameError,
};
use serde_json::{Value, json};

use crate::args::{ListArgs, PairCommand, PairGrantArgs, PairRevokeArgs, StateDirArgs};
use crate::failure::Failure;
use crate::host::Host;
use crate::render::rfc3339;

/// Runs `dsync pair <command>`, returning its exit code.
pub async fn pair(command: PairCommand, host: &Host) -> Result<u8, Failure> {
    match command {
        PairCommand::Show(args) => show::show(args, host).await,
        PairCommand::Accept(args) => accept::accept(args, host).await,
        PairCommand::List(args) => list(&args, host),
        PairCommand::Revoke(args) => revoke(&args, host),
        PairCommand::Grant(args) => grant(&args, host),
        PairCommand::Renew(state) => renew(&state, host),
    }
}

fn state_dir(args: &StateDirArgs, host: &Host) -> Result<StateDir, Failure> {
    StateDir::resolve(&args.choice()?, &host.facts).map_err(Failure::error)
}

/// `--name` as a device name. A blank one ([`PeerNameError::Empty`]) is
/// reported like a missing one.
fn peer_name(text: &str, missing: &str) -> Result<PeerName, Failure> {
    PeerName::parse(text).map_err(|error| match error {
        PeerNameError::Empty => Failure::usage(missing),
        other => Failure::usage(format!("--name: {other}")),
    })
}

/// The id of the device paired as `name`.
fn named(devices: &PairedDevices, name: &str) -> Option<DeviceId> {
    let name = PeerName::parse(name).ok()?;
    devices.by_name(&name).map(PairedDevice::device_id)
}

fn not_paired(command: &str, name: &str) -> Failure {
    Failure::Fatal(format!(
        "dsync pair {command}: no paired device named \"{name}\"."
    ))
}

/// `dsync pair list`: read-only, and never failing on its own account
/// once the store reads.
fn list(args: &ListArgs, host: &Host) -> Result<u8, Failure> {
    let state = state_dir(&args.state, host)?;
    let devices = PairedDeviceStore::new(&state)
        .load()
        .map_err(Failure::error)?;
    let mut out = io::stdout().lock();
    if args.json {
        for device in devices.iter() {
            let _ = writeln!(out, "{}", device_json(device));
        }
    } else if devices.is_empty() {
        let _ = writeln!(out, "No paired devices.");
    } else {
        for device in devices.iter() {
            let _ = writeln!(out, "{}", device_line(device));
        }
    }
    drop(out);
    warn_of_expiry(&state, &devices);
    Ok(0)
}

/// One device as `pair list` prints it.
fn device_line(device: &PairedDevice) -> String {
    let roots = if device.granted_roots().is_empty() {
        "(no replica roots granted — see `dsync pair grant`)".to_owned()
    } else {
        let roots: Vec<&str> = device.granted_roots().iter().map(String::as_str).collect();
        roots.join(", ")
    };
    format!(
        "{}  {}  {}  roots: {roots}",
        device.name(),
        device.device_id(),
        device.last_known_address()
    )
}

/// One device as a `--json` line. An empty root list is itself the fact
/// worth reporting (pairing alone reaches nothing), so it is written, not
/// omitted.
fn device_json(device: &PairedDevice) -> Value {
    let address = device.last_known_address();
    json!({
        "type": "pairedDevice",
        "name": device.name().as_str(),
        "deviceId": device.device_id().to_string(),
        "agreedReplicaRoots": device.granted_roots(),
        "pairedAt": rfc3339(device.paired_at()),
        "lastKnownAddress": {"host": address.host(), "port": address.port()},
    })
}

/// SPEC §4.4's expiry warnings, this host's certificate and each peer's,
/// on stderr in both modes: never inside a `--json` stream. This host's
/// identity is read only if one exists: listing mints nothing.
fn warn_of_expiry(state: &StateDir, devices: &PairedDevices) {
    let mut err = io::stderr().lock();
    let own = match DeviceIdentityStore::new(state).load() {
        Ok(own) => own.map(|identity| {
            (
                CertificateOwner::ThisHost,
                identity.certificate().validity(),
            )
        }),
        Err(error) => {
            let _ = writeln!(err, "warning: {error}");
            None
        }
    };
    let peers = devices.iter().map(|device| {
        (
            CertificateOwner::Peer(device.name().clone()),
            device.certificate().validity(),
        )
    });
    let now = SystemTime::now();
    for (owner, validity) in own.into_iter().chain(peers) {
        if let Some(expiry) = validity.expiry_within(owner, now, CertificateExpiry::DEFAULT_WINDOW)
        {
            let _ = writeln!(err, "warning: {expiry}");
        }
    }
}

/// `dsync pair revoke <name>`: local only; nothing is sent to the device.
fn revoke(args: &PairRevokeArgs, host: &Host) -> Result<u8, Failure> {
    let state = state_dir(&args.state, host)?;
    let store = PairedDeviceStore::new(&state);
    let devices = store.load().map_err(Failure::error)?;
    let id = named(&devices, &args.name).ok_or_else(|| not_paired("revoke", &args.name))?;
    store
        .update(|devices| devices.revoke(&id))
        .map_err(Failure::error)?;
    println!("revoked: {} ({id})", args.name);
    Ok(0)
}

/// `dsync pair grant <name> <path>`: the root stored expanded, as the
/// peer listener expands a requested root before checking it
/// ([`dsync_domain::ReplicaSpec::expanded_root`]), so the two compare
/// byte for byte.
fn grant(args: &PairGrantArgs, host: &Host) -> Result<u8, Failure> {
    let facts = &host.facts;
    let root = Location::parse(&args.path, facts.platform())
        .map_err(|error| error.to_string())
        .and_then(|location| {
            location
                .expanded_path(facts.home())
                .map_err(|error| error.to_string())
        })
        .map_err(|error| Failure::usage(format!("dsync pair grant: not a valid path: {error}")))?;
    let state = state_dir(&args.state, host)?;
    let store = PairedDeviceStore::new(&state);
    let devices = store.load().map_err(Failure::error)?;
    let id = named(&devices, &args.name).ok_or_else(|| not_paired("grant", &args.name))?;
    store
        .update(|devices| devices.grant(&id, root.clone(), resolve_grant))
        .map_err(Failure::error)?;
    println!("granted: \"{}\" may now reach {root}", args.name);
    Ok(0)
}

/// `dsync pair renew`: the same key, a fresh certificate. A host with no
/// identity gets one first - renewing a certificate nobody pins yet is
/// harmless; a half-written one is refused.
fn renew(args: &StateDirArgs, host: &Host) -> Result<u8, Failure> {
    let state = state_dir(args, host)?;
    let store = DeviceIdentityStore::new(&state);
    let now = SystemTime::now();
    let renewed = store
        .load_or_create(&Host::name(), now)
        .and_then(|_| store.renew(None, now))
        .map_err(|error| Failure::Fatal(format!("dsync pair renew: {error}")))?;
    println!("renewed: device id {} (unchanged)", renewed.device_id());
    println!(
        "Paired devices pick the new certificate up the next time they connect to this host; \
         until each has, syncs started from here to that device are refused."
    );
    Ok(0)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::time::Duration;

    use dsync_core::DeviceIdentity;
    use dsync_domain::host_port::PeerAddress;

    use super::*;

    fn phone(roots: &[&str]) -> PairedDevice {
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_789_470_000);
        let identity = DeviceIdentity::generate("phone", at).unwrap();
        let mut device = PairedDevice::new(
            identity.certificate().clone(),
            PeerName::parse("phone").unwrap(),
            PeerAddress::new("192.168.1.5", 28771).unwrap(),
            at,
        );
        for root in roots {
            device
                .grant((*root).to_owned(), |root: &str| PathBuf::from(root))
                .unwrap();
        }
        device
    }

    #[test]
    fn a_line_names_the_device_its_id_address_and_roots() {
        let device = phone(&["/home/me/notes"]);
        let line = device_line(&device);
        assert!(line.starts_with("phone  "), "{line}");
        assert!(line.contains(&device.device_id().to_string()), "{line}");
        assert!(line.contains("192.168.1.5:28771"), "{line}");
        assert!(line.ends_with("roots: /home/me/notes"), "{line}");
        assert!(device_line(&phone(&[])).contains("no replica roots granted"));
    }

    #[test]
    fn a_json_line_carries_every_field_and_an_empty_root_list() {
        let device = phone(&["/home/me/notes"]);
        let line = device_json(&device);
        assert_eq!(line["type"], "pairedDevice");
        assert_eq!(line["name"], "phone");
        assert_eq!(line["deviceId"], device.device_id().to_string());
        assert_eq!(line["agreedReplicaRoots"], json!(["/home/me/notes"]));
        assert_eq!(
            line["lastKnownAddress"],
            json!({"host": "192.168.1.5", "port": 28771})
        );
        assert!(
            line["pairedAt"]
                .as_str()
                .unwrap()
                .starts_with("2026-09-15T")
        );
        assert_eq!(device_json(&phone(&[]))["agreedReplicaRoots"], json!([]));
    }

    #[test]
    fn a_blank_or_unaddressable_name_is_a_usage_error() {
        assert!(matches!(peer_name("  ", "needs"), Err(Failure::Usage(m)) if m == "needs"));
        assert!(matches!(peer_name("a:b", "needs"), Err(Failure::Usage(_))));
        assert_eq!(peer_name("phone", "needs").unwrap().as_str(), "phone");
    }
}
