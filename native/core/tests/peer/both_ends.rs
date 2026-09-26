//! Both ends of a peer:// pairing starting a run at each other at once:
//! each run is a different profile, so only the folder lock (SPEC §4.3)
//! stands between them. The second run is refused on either path to the
//! folder the first holds - locally, and through the first run's serving
//! end.

use std::net::SocketAddr;
use std::path::Path;

use dsync_core::{LocalReplica, LockError, RemoteReplica, Replica, ReplicaError};
use dsync_domain::{Jobs, ProfileId, ReplicaSpec, Side, Tuning};

use crate::support::{Host, address_of, identity, serve, with_deadline};

/// The run started on the desktop, and the one started on the phone.
const DESKTOP_RUN: &str = "0123456789abcdef0123456789abcdef";
const PHONE_RUN: &str = "fedcba9876543210fedcba9876543210";

fn local(host: &Host, root: &Path, profile: &str) -> LocalReplica {
    LocalReplica::open(
        root.to_str().unwrap().to_owned(),
        host.state(),
        ProfileId::parse(profile).unwrap(),
        Side::A,
        Jobs::DEFAULT,
        Tuning::DEFAULT,
    )
    .unwrap()
}

/// `root` on the device paired on `host` as `label`, as side B of
/// `profile`, said hello to.
async fn remote(
    host: &Host,
    label: &str,
    at: SocketAddr,
    root: &Path,
    profile: &str,
) -> RemoteReplica {
    let spec = ReplicaSpec {
        root: root.to_str().unwrap().to_owned(),
        profile: ProfileId::parse(profile).unwrap(),
        side: Side::B,
        jobs: Jobs::DEFAULT,
    };
    let id = host.paired(label).device_id();
    let dialed = with_deadline("dial", host.dialer().dial(&id, Some(address_of(at)), spec))
        .await
        .unwrap();
    with_deadline("hello", dialed.replica.hello())
        .await
        .unwrap();
    dialed.replica
}

fn assert_folder_in_use(result: Result<(), ReplicaError>, folder: &Path) {
    let folder = std::fs::canonicalize(folder).unwrap();
    assert!(
        matches!(&result, Err(ReplicaError::Lock(LockError::FolderInUse { folder: named, .. }))
            if named == &folder),
        "{result:?}"
    );
}

#[tokio::test]
async fn the_second_of_two_runs_started_at_each_other_is_refused() {
    let desktop = Host::new(identity("desktop"));
    let phone = Host::new(identity("phone"));
    let (on_desktop, on_phone) = (desktop.root("notes"), phone.root("notes"));
    std::fs::create_dir_all(&on_desktop).unwrap();
    std::fs::create_dir_all(&on_phone).unwrap();
    let desktop_serving = serve(&desktop).await;
    let phone_serving = serve(&phone).await;
    desktop.pair(
        &phone.identity,
        "phone",
        address_of(phone_serving.at),
        &[on_desktop.as_path()],
    );
    phone.pair(
        &desktop.identity,
        "desktop",
        address_of(desktop_serving.at),
        &[on_phone.as_path()],
    );

    // The desktop's run holds its own folder and, through the phone's
    // serving end, the phone's.
    let first_a = local(&desktop, &on_desktop, DESKTOP_RUN);
    with_deadline("lock", first_a.lock()).await.unwrap();
    let first_b = remote(&desktop, "phone", phone_serving.at, &on_phone, DESKTOP_RUN).await;
    with_deadline("lock", first_b.lock()).await.unwrap();

    // The phone's run reaches the same two folders by the other roles.
    let second_a = local(&phone, &on_phone, PHONE_RUN);
    let second_b = remote(
        &phone,
        "desktop",
        desktop_serving.at,
        &on_desktop,
        PHONE_RUN,
    )
    .await;
    assert_folder_in_use(with_deadline("lock", second_a.lock()).await, &on_phone);
    assert_folder_in_use(with_deadline("lock", second_b.lock()).await, &on_desktop);

    // Once the first run lets go, the second one runs.
    with_deadline("unlock", first_b.unlock()).await.unwrap();
    with_deadline("unlock", first_a.unlock()).await.unwrap();
    with_deadline("lock", second_a.lock()).await.unwrap();
    with_deadline("lock", second_b.lock()).await.unwrap();
    with_deadline("unlock", second_b.unlock()).await.unwrap();
    with_deadline("unlock", second_a.unlock()).await.unwrap();
    for replica in [first_b, second_b] {
        with_deadline("close", replica.close()).await.unwrap();
    }
}
