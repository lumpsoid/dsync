//! A `peer://` location is pinned to a device id, not its cosmetic name
//! (SPEC §4.4, plan D7/OQ6): the connector dials the id, so renaming a
//! paired device does not break a profile naming it, and a different
//! device that later takes the old name is never dialled in its place.

use std::sync::Arc;

use dsync_core::{Connector, PeerDialer, PeerSessions, Replica};
use dsync_domain::{
    Command, DeviceId, EffectiveOptions, Flags, HostFacts, Location, Platform, ReplicaLocation,
    RunFlags, Tuning,
};

use crate::peer::support::{Host, address_of, identity, name, serve, somewhere, with_deadline};

/// `client`'s options for A (a local root under its own temp dir) and B
/// (`peer://desktop:<path>`, pinned to `pinned`) - built once, as a
/// profile would carry them, whatever `client`'s store later calls the
/// pinned device.
fn options(client: &Host, pinned: DeviceId, path: &str) -> EffectiveOptions {
    let local_root = client.root("local");
    std::fs::create_dir_all(&local_root).unwrap();
    let a = ReplicaLocation::new(
        Location::parse(local_root.to_str().unwrap(), Platform::HOST).unwrap(),
        None,
    )
    .unwrap();
    let b = ReplicaLocation::new(
        Location::parse(&format!("peer://desktop:{path}"), Platform::HOST).unwrap(),
        Some(pinned),
    )
    .unwrap();
    EffectiveOptions::for_ad_hoc(
        a,
        b,
        &RunFlags::validate(Command::Sync, Flags::default()).unwrap(),
        &HostFacts::new(
            Platform::HOST,
            Some(client.home().to_str().unwrap().to_owned()),
            [],
            "/".to_owned(),
        ),
        &[],
    )
    .unwrap()
}

fn connector(client: &Host) -> Connector {
    Connector::new(
        client.state(),
        Some(client.home().to_str().unwrap().to_owned()),
        Tuning::DEFAULT,
        dsync_domain::SpoolSetting::Off,
    )
    .with_peers(PeerDialer::new(
        client.identity.clone(),
        client.store(),
        Tuning::DEFAULT,
        Arc::new(PeerSessions::new()),
    ))
}

#[tokio::test]
async fn a_device_renamed_after_pinning_still_connects_with_unchanged_options() {
    let server = Host::new(identity("desktop-box"));
    let client = Host::new(identity("phone"));
    let serving = serve(&server).await;
    server.pair(&client.identity, "phone", somewhere(), &[]);
    client.pair(&server.identity, "desktop", address_of(serving.at), &[]);
    let pinned = server.identity.device_id();
    let options = options(&client, pinned, "/sdcard/notes");

    // Renamed after the options were built - the location string still
    // says "desktop".
    client
        .store()
        .update(|devices| devices.rename(&pinned, name("desktop-renamed")))
        .unwrap();

    let connected = with_deadline("connect", connector(&client).connect(&options))
        .await
        .unwrap_or_else(|error| panic!("the rename broke the dial: {error}"));
    assert_eq!(connected.peers[0].device, pinned);
    with_deadline("close", connected.b.close()).await.unwrap();
}

#[tokio::test]
async fn a_different_device_that_takes_the_old_name_is_never_dialled_in_its_place() {
    let client = Host::new(identity("phone"));
    let original = Host::new(identity("desktop-original"));
    let impostor = Host::new(identity("desktop-new"));
    original.pair(&client.identity, "phone", somewhere(), &[]);
    let serving_original = serve(&original).await;
    let serving_impostor = serve(&impostor).await;

    client.pair(
        &original.identity,
        "desktop",
        address_of(serving_original.at),
        &[],
    );
    let pinned = original.identity.device_id();
    let options = options(&client, pinned, "/sdcard/notes");

    // The name is freed, then taken by a different device entirely - a
    // device this host can really reach, so a dial gone astray would
    // succeed against it rather than merely fail unreachable. The options
    // still say "desktop" and are still pinned to the original.
    client
        .store()
        .update(|devices| devices.rename(&pinned, name("desktop-original")))
        .unwrap();
    client.pair(
        &impostor.identity,
        "desktop",
        address_of(serving_impostor.at),
        &[],
    );

    let connected = with_deadline("connect", connector(&client).connect(&options))
        .await
        .unwrap_or_else(|error| panic!("{error}"));

    assert_eq!(connected.peers[0].device, pinned, "dialled the pinned id");
    assert_eq!(
        connected.peers[0].address,
        address_of(serving_original.at),
        "dialled the original, not whoever now answers to \"desktop\""
    );
    with_deadline("close", connected.b.close()).await.unwrap();
}
