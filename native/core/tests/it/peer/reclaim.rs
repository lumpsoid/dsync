//! A dialer reclaiming the session its dropped link left behind (SPEC
//! §4.2, §4.3): the token the listener issued on the last connection,
//! presented on the next, ends that session and frees its locks at once -
//! not at the far side's silence limit - and only for the device that
//! held it. Real TLS through a relay the tests break (`cut_link`); each
//! test re-dials by hand with the same `PeerSessions`.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use dsync_core::{
    LinkError, LockError, PeerDialer, PeerEvent, PeerSessions, RemoteReplica, Replica,
    ReplicaError, body_channel,
};
use dsync_domain::{
    ContentHash, EntryId, FileMeta, FileState, Precondition, RelPath, ReplicaSpec, Tuning,
};

use crate::cut_link::CutLink;
use crate::peer::support::{Host, Serving, address_of, identity, serve_with, somewhere, spec};

const OTHER_ENTRY: &str = "fedcba9876543210fedcba9876543210";

/// A bound for the steps that wait out the dialer's silence limit.
const SLOW: Duration = Duration::from_secs(15);

async fn within<T>(label: &str, work: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(SLOW, work)
        .await
        .unwrap_or_else(|_| panic!("{label} did not finish within {SLOW:?}"))
}

/// The far side would hold a dead session for a minute on its own.
fn far_tuning() -> Tuning {
    Tuning {
        heartbeat: Duration::from_millis(250),
        silence_limit: Duration::from_secs(60),
        ..Tuning::DEFAULT
    }
}

/// The dialer gives up on a silent link after a second.
fn near_tuning() -> Tuning {
    Tuning {
        heartbeat: Duration::from_millis(250),
        silence_limit: Duration::from_secs(1),
        ..Tuning::DEFAULT
    }
}

/// A desktop serving `notes` to a phone, through a relay the test can
/// break.
struct Scene {
    server: Host,
    phone: Host,
    root: PathBuf,
    serving: Serving,
    link: CutLink,
}

async fn scene() -> Scene {
    let server = Host::new(identity("desktop"));
    let phone = Host::new(identity("phone"));
    let root = server.root("notes");
    let photos = server.root("photos");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&photos).unwrap();
    server.pair(
        &phone.identity,
        "phone",
        somewhere(),
        &[root.as_path(), photos.as_path()],
    );
    phone.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve_with(&server, far_tuning()).await;
    let link = CutLink::to(serving.at).await;
    Scene {
        server,
        phone,
        root,
        serving,
        link,
    }
}

impl Scene {
    /// `notes`, dialled through the relay as `client` remembering its
    /// sessions in `sessions`, said hello to: the lock's outcome and the
    /// replica.
    async fn dial(
        &self,
        client: &Host,
        sessions: &Arc<PeerSessions>,
    ) -> (Result<(), ReplicaError>, RemoteReplica) {
        self.dial_spec(client, sessions, spec(self.root.to_str().unwrap()))
            .await
    }

    async fn dial_spec(
        &self,
        client: &Host,
        sessions: &Arc<PeerSessions>,
        spec: ReplicaSpec,
    ) -> (Result<(), ReplicaError>, RemoteReplica) {
        let dialer = PeerDialer::new(
            client.identity.clone(),
            client.store(),
            near_tuning(),
            sessions.clone(),
        );
        let dialed = within(
            "dial",
            dialer.dial(
                &self.server.identity.device_id(),
                Some(address_of(self.link.at)),
                spec,
            ),
        )
        .await
        .unwrap();
        let replica = dialed.replica;
        within("hello", replica.hello()).await.unwrap();
        let locked = within("lock", replica.lock()).await.map(|_| ());
        (locked, replica)
    }

    /// Waits for the listener to report a session ended.
    async fn ended(&mut self) {
        loop {
            if let PeerEvent::Ended { .. } = self.serving.next_event().await {
                return;
            }
        }
    }
}

fn assert_held(locked: Result<(), ReplicaError>) {
    assert!(
        matches!(locked, Err(ReplicaError::Lock(LockError::Held { .. }))),
        "{locked:?}"
    );
}

fn assert_silent(result: Result<(), ReplicaError>) {
    assert!(
        matches!(
            result,
            Err(ReplicaError::Link(LinkError::PeerSilent { .. }))
        ),
        "{result:?}"
    );
}

fn rel(path: &str) -> RelPath {
    RelPath::parse(path).unwrap()
}

/// Larger than the outbox, the relay's and both sockets' buffers.
const BIG: usize = 48 * 1024 * 1024;

/// The phone locks `notes` and starts pulling a big file; the link goes
/// dark mid-stream, and the phone's own silence limit gives up on it.
/// The far side still holds the session, mid-read, with its locks.
async fn dropped_mid_pull(scene: &Scene, sessions: &Arc<PeerSessions>) {
    std::fs::write(scene.root.join("big.bin"), vec![7u8; BIG]).unwrap();
    let (locked, first) = scene.dial(&scene.phone, sessions).await;
    locked.unwrap();
    let mut reading = within("read", first.read(&rel("big.bin"))).await.unwrap();
    within("a first chunk", reading.body.next())
        .await
        .unwrap()
        .unwrap();
    scene.link.black_hole();
    let started = Instant::now();
    within("the dead link failing the body", async {
        while let Ok(Some(_)) = reading.body.next().await {}
    })
    .await;
    assert!(started.elapsed() >= near_tuning().silence_limit);
    assert_silent(within("unlock", first.unlock()).await);
}

#[tokio::test]
async fn a_claim_ends_the_session_a_dead_pull_left_and_frees_its_lock() {
    let scene = scene().await;
    let sessions = Arc::new(PeerSessions::new());
    dropped_mid_pull(&scene, &sessions).await;

    let started = Instant::now();
    let (locked, second) = scene.dial(&scene.phone, &sessions).await;
    locked.unwrap();
    assert!(
        started.elapsed() < far_tuning().reclaim_wait,
        "{:?}",
        started.elapsed()
    );
    within("unlock", second.unlock()).await.unwrap();
    within("close", second.close()).await.unwrap();
}

/// Positive control: the same dead pull, re-dialled without the token,
/// meets the lock the dead session still holds.
#[tokio::test]
async fn without_the_claim_the_dead_pull_still_holds_the_lock() {
    let scene = scene().await;
    dropped_mid_pull(&scene, &Arc::new(PeerSessions::new())).await;
    let (locked, _second) = scene
        .dial(&scene.phone, &Arc::new(PeerSessions::new()))
        .await;
    assert_held(locked);
}

/// The push direction: the phone is writing big bodies to the desktop
/// when the link goes dark. Every write fails at the phone's own silence
/// limit - none waits on its own full outbox - and the claim then frees
/// the far side's lock with those writes half-received.
#[tokio::test]
async fn a_claim_ends_the_session_a_dead_push_left_and_frees_its_lock() {
    let scene = scene().await;
    let sessions = Arc::new(PeerSessions::new());
    let (locked, first) = scene.dial(&scene.phone, &sessions).await;
    locked.unwrap();
    // Never whole: the link dies first, so the hash is never checked.
    let source = FileState {
        meta: FileMeta {
            size: BIG as u64,
            mtime_us: 1_704_067_200_000_000,
            mode: 0o644,
        },
        hash: ContentHash::from_digest([0; 32]),
    };
    let (feeding, writes): (Vec<_>, Vec<_>) = (0..32)
        .map(|n| {
            let (sender, body) = body_channel(4);
            let feeding = tokio::spawn(async move {
                let mut sent = 0;
                while sent < BIG && sender.send(vec![n as u8; 64 * 1024]).await.is_ok() {
                    sent += 64 * 1024;
                }
            });
            (feeding, (rel(&format!("pushed-{n}.bin")), body))
        })
        .unzip();
    let writing = futures_util::future::join_all(writes.into_iter().map(|(path, body)| {
        let first = &first;
        async move { first.write(&path, body, source, Precondition::Absent).await }
    }));
    let black_hole = async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        scene.link.black_hole();
    };
    let (written, ()) = within("the writes on a dead link", async {
        tokio::join!(writing, black_hole)
    })
    .await;
    for write in written {
        assert!(
            matches!(write, Err(ReplicaError::Link(LinkError::PeerSilent { .. }))),
            "{write:?}"
        );
    }
    for feeding in feeding {
        feeding.abort();
    }
    drop(first);

    let (locked, second) = scene.dial(&scene.phone, &sessions).await;
    locked.unwrap();
    within("unlock", second.unlock()).await.unwrap();
    within("close", second.close()).await.unwrap();
}

/// Another device presenting the phone's token - here a tablet sharing
/// the phone's session memory - ends nothing: its lock meets the phone's,
/// and the phone's session carries on.
#[tokio::test]
async fn another_devices_claim_is_ignored() {
    let scene = scene().await;
    let tablet = Host::new(identity("tablet"));
    scene.server.pair(
        &tablet.identity,
        "tablet",
        somewhere(),
        &[scene.root.as_path()],
    );
    tablet.pair(&scene.server.identity, "desktop", somewhere(), &[]);
    let sessions = Arc::new(PeerSessions::new());
    let (locked, phone) = scene.dial(&scene.phone, &sessions).await;
    locked.unwrap();

    let (locked, _tablet) = scene.dial(&tablet, &sessions).await;
    assert_held(locked);
    within("the phone's unlock", phone.unlock()).await.unwrap();
    within("close", phone.close()).await.unwrap();
}

/// A second session from the same device, never given the first's token
/// (the CLI beside the app), cannot take the first over.
#[tokio::test]
async fn a_second_session_without_the_claim_ends_nothing() {
    let scene = scene().await;
    let (locked, first) = scene
        .dial(&scene.phone, &Arc::new(PeerSessions::new()))
        .await;
    locked.unwrap();

    let (locked, _second) = scene
        .dial(&scene.phone, &Arc::new(PeerSessions::new()))
        .await;
    assert_held(locked);
    within("the first's unlock", first.unlock()).await.unwrap();
    within("close", first.close()).await.unwrap();
}

/// A token dies with its session: after a clean unlock and close, the
/// claim names nothing, and the dial it rides on works and ends nothing
/// else.
#[tokio::test]
async fn a_closed_sessions_token_is_unknown() {
    let mut scene = scene().await;
    let sessions = Arc::new(PeerSessions::new());
    let (locked, first) = scene.dial(&scene.phone, &sessions).await;
    locked.unwrap();
    within("unlock", first.unlock()).await.unwrap();
    within("close", first.close()).await.unwrap();
    scene.ended().await;

    // A live session of the same device for another entry, on another
    // folder: the stale claim must not reach it.
    let photos = ReplicaSpec {
        entry: EntryId::parse(OTHER_ENTRY).unwrap(),
        ..spec(scene.server.root("photos").to_str().unwrap())
    };
    let (locked, bystander) = scene
        .dial_spec(&scene.phone, &Arc::new(PeerSessions::new()), photos)
        .await;
    locked.unwrap();

    let (locked, again) = scene.dial(&scene.phone, &sessions).await;
    locked.unwrap();
    within("unlock", again.unlock()).await.unwrap();
    within("close", again.close()).await.unwrap();
    within("the bystander's unlock", bystander.unlock())
        .await
        .unwrap();
    within("close", bystander.close()).await.unwrap();
}

/// The relay's other two breaks, as Phase 3's re-dial meets them: a cut
/// link fails the session's next call at once, a refusing one fails a
/// dial as unreachable, and once it admits again the dial goes through.
#[tokio::test]
async fn a_cut_link_fails_at_once_and_a_refusing_one_is_unreachable() {
    let scene = scene().await;
    let sessions = Arc::new(PeerSessions::new());
    let (locked, first) = scene.dial(&scene.phone, &sessions).await;
    locked.unwrap();
    scene.link.cut();
    let started = Instant::now();
    assert!(within("unlock", first.unlock()).await.is_err());
    assert!(started.elapsed() < near_tuning().silence_limit);

    scene.link.refuse().await;
    let dialer = PeerDialer::new(
        scene.phone.identity.clone(),
        scene.phone.store(),
        near_tuning(),
        sessions.clone(),
    );
    let refused = within(
        "dial",
        dialer.dial(
            &scene.server.identity.device_id(),
            Some(address_of(scene.link.at)),
            spec(scene.root.to_str().unwrap()),
        ),
    )
    .await;
    assert!(
        matches!(&refused, Err(error) if error.is_unreachable()),
        "{:?}",
        refused.map(|_| ())
    );

    scene.link.admit().await;
    let (locked, again) = scene.dial(&scene.phone, &sessions).await;
    locked.unwrap();
    within("unlock", again.unlock()).await.unwrap();
    within("close", again.close()).await.unwrap();
}
