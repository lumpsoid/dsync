//! The connector: the cases of `connected_replicas_test.dart` - which
//! transport each location takes, and the distinct failures of each.

use std::time::SystemTime;

use dsync_core::{
    AnyReplica, ConnectError, ConnectFailure, Connector, DeviceIdentity, LinkError, PairedDevice,
    PairedDeviceStore, PeerDialError, PeerDialer, Replica, StateDir,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    Command, EffectiveOptions, Flags, HostFacts, Location, PeerName, Platform, ReplicaLocation,
    ReplicaRoot, RunFlags, Side, Tuning,
};

use crate::support::{Site, serve, with_deadline};

fn options(first: ReplicaLocation, second: ReplicaLocation, local: &[String]) -> EffectiveOptions {
    EffectiveOptions::for_ad_hoc(
        first,
        second,
        &RunFlags::validate(Command::Sync, Flags::default()).unwrap(),
        &HostFacts::new(Platform::HOST, None, [], "/".to_owned()),
        local,
    )
    .unwrap()
}

fn at(raw: &str) -> ReplicaLocation {
    ReplicaLocation::new(Location::parse(raw, Platform::HOST).unwrap(), None).unwrap()
}

fn root(site: &Site, side: Side) -> String {
    site.root(side).to_str().unwrap().to_owned()
}

fn connector(site: &Site) -> Connector {
    Connector::new(site.state(), None, Tuning::DEFAULT)
}

async fn connect(
    connector: &Connector,
    options: &EffectiveOptions,
) -> Result<(AnyReplica, AnyReplica), ConnectError> {
    with_deadline("connect", connector.connect(options)).await
}

fn local_root(replica: &AnyReplica) -> Option<String> {
    match replica {
        AnyReplica::Local(local) => Some(local.root().to_str().unwrap().to_owned()),
        AnyReplica::Remote(_) => None,
    }
}

#[tokio::test]
async fn two_local_locations_open_two_local_replicas_at_their_roots() {
    let site = Site::new();
    let options = options(at(&root(&site, Side::A)), at(&root(&site, Side::B)), &[]);

    let (a, b) = connect(&connector(&site), &options).await.unwrap();

    assert_eq!(local_root(&a), Some(root(&site, Side::A)));
    assert_eq!(local_root(&b), Some(root(&site, Side::B)));
    let info = a.hello().await.unwrap();
    assert_eq!(info.root, ReplicaRoot::Present);
    assert_eq!(
        info.archive_path.as_deref(),
        site.state()
            .archive_log(&options.profile_id, Side::A)
            .to_str()
    );
}

#[tokio::test]
async fn a_host_among_the_local_addresses_is_served_in_process() {
    let site = Site::new();
    let local = vec!["thishost".to_owned()];
    let options = options(
        at(&root(&site, Side::A)),
        at(&format!("thishost:{}", root(&site, Side::B))),
        &local,
    );

    let (_, b) = connect(&connector(&site).with_local_addresses(local), &options)
        .await
        .unwrap();

    assert_eq!(local_root(&b), Some(root(&site, Side::B)));
}

/// The side a connection over ssh failed on, with a stand-in `ssh` that
/// exits at once - proof that ssh was what the side reached for.
async fn fails_over_ssh(site: &Site, remote: &str, local: Vec<String>) -> Side {
    let options = options(at(&root(site, Side::A)), at(remote), &local);
    let connector = connector(site)
        .with_local_addresses(local)
        .with_ssh_program("false");
    let Err(error) = connect(&connector, &options).await else {
        panic!("{remote} connected");
    };
    assert!(
        matches!(error.failure, ConnectFailure::Link(LinkError::Ssh { .. })),
        "{error:?}"
    );
    error.side
}

#[tokio::test]
async fn a_host_absent_from_the_local_addresses_is_reached_over_ssh() {
    let site = Site::new();
    assert_eq!(
        fails_over_ssh(&site, "elsewhere:/srv/notes", vec![]).await,
        Side::B
    );
    // Positive control: the same host, known as this machine, is not.
    let options = options(
        at(&root(&site, Side::A)),
        at(&format!("elsewhere:{}", root(&site, Side::B))),
        &["elsewhere".to_owned()],
    );
    let connected = connector(&site)
        .with_local_addresses(vec!["elsewhere".to_owned()])
        .with_ssh_program("false")
        .connect(&options)
        .await;
    assert!(connected.is_ok());
}

#[tokio::test]
async fn an_ssh_url_is_remote_even_when_its_host_is_this_machine() {
    let site = Site::new();
    assert_eq!(
        fails_over_ssh(
            &site,
            "ssh://thishost:/srv/notes",
            vec!["thishost".to_owned()]
        )
        .await,
        Side::B
    );
}

/// Connects `options` while serving, on `listener`, the one session its
/// connector opens there.
#[cfg(unix)]
async fn connect_serving(
    site: &Site,
    options: &EffectiveOptions,
    listener: tokio::net::UnixListener,
) -> (
    Result<(AnyReplica, AnyReplica), ConnectError>,
    tokio::task::JoinHandle<Result<(), LinkError>>,
) {
    let connector = connector(site);
    let serving = async {
        let (stream, _) = listener.accept().await.unwrap();
        Session(serve(site, stream))
    };
    let (connected, Session(session)) = with_deadline("connect", async {
        tokio::join!(connector.connect(options), serving)
    })
    .await;
    (connected, session)
}

/// A served session's task, as a value rather than a future to await.
#[cfg(unix)]
struct Session(tokio::task::JoinHandle<Result<(), LinkError>>);

#[cfg(unix)]
#[tokio::test]
async fn a_unix_location_is_a_remote_replica_over_the_socket() {
    let site = Site::new();
    let socket = site.root(Side::A).with_file_name("agent.sock");
    let listener = dsync_core::bind_unix(&socket).await.unwrap();
    let options = options(
        at(&root(&site, Side::A)),
        at(&format!(
            "unix://{}:{}",
            socket.display(),
            root(&site, Side::B)
        )),
        &[],
    );

    let (connected, session) = connect_serving(&site, &options, listener).await;

    let (a, b) = connected.unwrap();
    assert!(local_root(&a).is_some());
    assert!(local_root(&b).is_none(), "side B is remote");
    let info = with_deadline("hello", b.hello()).await.unwrap();
    assert_eq!(info.root, ReplicaRoot::Present);
    with_deadline("close", b.close()).await.unwrap();
    with_deadline("the session", session)
        .await
        .unwrap()
        .unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn a_socket_with_no_agent_behind_it_is_an_unreachable_replica() {
    let site = Site::new();
    let socket = site.root(Side::A).with_file_name("nobody.sock");
    let options = options(
        at(&root(&site, Side::A)),
        at(&format!("unix://{}:/srv", socket.display())),
        &[],
    );

    let Err(error) = connect(&connector(&site), &options).await else {
        panic!("connected to nobody");
    };

    assert_eq!(error.side, Side::B);
    assert!(
        matches!(error.failure, ConnectFailure::Socket { .. }),
        "{error:?}"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn a_side_that_fails_after_the_other_connected_closes_it() {
    let site = Site::new();
    let served = site.root(Side::A).with_file_name("a.sock");
    let missing = site.root(Side::A).with_file_name("b.sock");
    let listener = dsync_core::bind_unix(&served).await.unwrap();
    let options = options(
        at(&format!(
            "unix://{}:{}",
            served.display(),
            root(&site, Side::A)
        )),
        at(&format!("unix://{}:/srv", missing.display())),
        &[],
    );
    assert!(
        matches!(options.replica(Side::A), ReplicaLocation::Unix(unix) if unix.socket() == served.to_str().unwrap())
    );

    let (connected, session) = connect_serving(&site, &options, listener).await;

    let Err(error) = connected else {
        panic!("side B has no agent");
    };
    assert_eq!(error.side, Side::B);
    with_deadline("side A's session ends", session)
        .await
        .unwrap()
        .unwrap();
}

fn peer_options(site: &Site, device: &str, id: &DeviceIdentity) -> EffectiveOptions {
    let peer = ReplicaLocation::new(
        Location::parse(&format!("peer://{device}:/sdcard/notes"), Platform::HOST).unwrap(),
        Some(id.device_id()),
    )
    .unwrap();
    options(at(&root(site, Side::A)), peer, &[])
}

fn dialer(state: &StateDir, me: &DeviceIdentity) -> PeerDialer {
    PeerDialer::new(me.clone(), PairedDeviceStore::new(state), Tuning::DEFAULT)
}

#[tokio::test]
async fn an_unpaired_device_name_fails_before_any_socket_naming_the_device() {
    let site = Site::new();
    let me = DeviceIdentity::generate("desktop", SystemTime::now()).unwrap();
    let phone = DeviceIdentity::generate("phone", SystemTime::now()).unwrap();
    let options = peer_options(&site, "phone", &phone);

    let Err(error) = connect(
        &connector(&site).with_peers(dialer(&site.state(), &me)),
        &options,
    )
    .await
    else {
        panic!("dialled an unpaired device");
    };

    assert_eq!(error.side, Side::B);
    let ConnectFailure::Peer(PeerDialError::NotPaired(name)) = &error.failure else {
        panic!("{error:?}");
    };
    assert_eq!(name.as_str(), "phone");
    assert!(error.to_string().contains("pair"), "{error}");
}

#[tokio::test]
async fn a_paired_device_whose_address_refuses_reports_that_address() {
    let site = Site::new();
    let me = DeviceIdentity::generate("desktop", SystemTime::now()).unwrap();
    let phone = DeviceIdentity::generate("phone", SystemTime::now()).unwrap();
    let closed = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };
    let address = PeerAddress::new("127.0.0.1", closed).unwrap();
    PairedDeviceStore::new(&site.state())
        .update(|devices| {
            devices.add(PairedDevice::new(
                phone.certificate().clone(),
                PeerName::parse("phone").unwrap(),
                address.clone(),
                SystemTime::now(),
            ))
        })
        .unwrap();
    let options = peer_options(&site, "phone", &phone);

    let Err(error) = connect(
        &connector(&site).with_peers(dialer(&site.state(), &me)),
        &options,
    )
    .await
    else {
        panic!("connected to a closed port");
    };

    let ConnectFailure::Peer(PeerDialError::Unreachable { address: tried, .. }) = &error.failure
    else {
        panic!("{error:?}");
    };
    assert_eq!(tried, &address);
}

#[tokio::test]
async fn a_peer_location_without_an_identity_to_dial_with_is_refused() {
    let site = Site::new();
    let phone = DeviceIdentity::generate("phone", SystemTime::now()).unwrap();
    let options = peer_options(&site, "phone", &phone);

    let Err(error) = connect(&connector(&site), &options).await else {
        panic!("dialled without an identity");
    };

    assert!(matches!(error.failure, ConnectFailure::NoIdentity));
}
