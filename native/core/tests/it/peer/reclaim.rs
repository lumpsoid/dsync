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
    ContentHash, EntryId, FileMeta, FileState, Precondition, RelPath, ReplicaSpec, Side,
    SpoolSetting, Tuning,
};

use crate::cut_link::CutLink;
use crate::peer::support::{
    Host, PROFILE, Serving, address_of, identity, serve_spooling, somewhere, spec,
};

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
    scene_serving(far_tuning(), SpoolSetting::Off).await
}

/// [`scene`], the desktop serving with `far` and spooling as `spool` says.
async fn scene_serving(far: Tuning, spool: SpoolSetting) -> Scene {
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
    let serving = serve_spooling(&server, far, spool).await;
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
        let replica = self.connect(client, sessions, spec).await;
        let locked = within("lock", replica.lock()).await.map(|_| ());
        (locked, replica)
    }

    /// The replica `spec` names, dialled through the relay as `client`
    /// remembering its sessions in `sessions`, said hello to, not locked.
    async fn connect(
        &self,
        client: &Host,
        sessions: &Arc<PeerSessions>,
        spec: ReplicaSpec,
    ) -> RemoteReplica {
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
        replica
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
            read_us: 1_800_000_000_000_000,
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

/// What `stage` ships for `content`: its scanned state, read well after
/// its mtime so the far side trusts it.
fn staged_source(content: &[u8]) -> FileState {
    let digest = ring::digest::digest(&ring::digest::SHA256, content);
    FileState {
        meta: FileMeta {
            size: content.len() as u64,
            mtime_us: 1_704_067_200_000_000,
            mode: 0o644,
            read_us: 1_800_000_000_000_000,
        },
        hash: ContentHash::from_digest(digest.as_ref().try_into().unwrap()),
    }
}

/// Every file anywhere under `dir`; none when it is missing.
fn files_under(dir: &std::path::Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files = Vec::new();
    for entry in entries {
        let entry = entry.unwrap();
        if entry.file_type().unwrap().is_dir() {
            files.extend(files_under(&entry.path()));
        } else {
            files.push(entry.path());
        }
    }
    files
}

/// The phone has staged three files to a spooling desktop, its one
/// writer held on the first, when the link goes dark. Its claim ends
/// that session, which still lands everything it took before its lock
/// goes, and the claim waits for it - far past `reclaim_wait`, told by
/// `Draining` frames that bytes are still queued - so the claimer's
/// lock, and so its scan, starts only after the last landing. A dial
/// that claims nothing meanwhile meets the held lock at once.
#[tokio::test]
async fn a_reclaim_waits_for_the_session_to_land_what_it_staged() {
    reclaim_while_landing(false).await;
}

/// The same, with the phone's `take_landed` long poll open when the link
/// goes dark, as an applier keeps one while a staged copy waits: the
/// ended session is still joining that request, not yet settling, while
/// its landings are held - and is waited on all the same.
#[tokio::test]
async fn a_reclaim_waits_for_a_session_still_joining_its_take_landed() {
    reclaim_while_landing(true).await;
}

async fn reclaim_while_landing(take_landed_open: bool) {
    let room = 1 << 20;
    let far = Tuning {
        writers: 1,
        spool_bytes: room,
        spool_reserve_bytes: 0,
        // Far below the drain: only the queued bytes keep the claim
        // waiting.
        reclaim_wait: Duration::from_millis(200),
        ..far_tuning()
    };
    let scene = scene_serving(far, SpoolSetting::On).await;
    let sessions = Arc::new(PeerSessions::new());
    let first = scene
        .connect(&scene.phone, &sessions, spec(scene.root.to_str().unwrap()))
        .await;
    let facts = within("lock", first.lock()).await.unwrap();
    assert_eq!(facts.spool_room, room, "the volume is short");
    let hold = dsync_core::LandingHold::at(&scene.root);
    let files: [(&str, &[u8]); 3] = [("a", b"first"), ("b", b"second"), ("c", b"third")];
    for (name, content) in files {
        within(
            name,
            first.stage(
                &rel(name),
                dsync_core::Body::from_bytes(content.to_vec()),
                staged_source(content),
                Precondition::Absent,
            ),
        )
        .await
        .unwrap();
    }
    within("a on the writer", hold.until_held(1)).await;
    // Answers only once a landing finishes, and `a` is held.
    let mut polling = Box::pin(first.take_landed());
    if take_landed_open {
        let sent = tokio::time::timeout(Duration::from_millis(200), &mut polling).await;
        assert!(sent.is_err(), "take_landed answered with a held: {sent:?}");
    }
    scene.link.black_hole();
    drop(polling);
    drop(first);

    // Many heartbeats, and many times `reclaim_wait`.
    let drain = 8 * far.heartbeat;
    let claiming = scene.connect(&scene.phone, &sessions, spec(scene.root.to_str().unwrap()));
    tokio::pin!(claiming);
    let landing = async {
        tokio::time::sleep(drain).await;
        // Without the claim: no wait, and the drained session's lock.
        let (locked, bystander) = scene
            .dial(&scene.phone, &Arc::new(PeerSessions::new()))
            .await;
        assert_held(locked);
        drop(bystander);
        assert!(!scene.root.join("a").exists());
        // `a` lands; `b` goes to the writer and is held there, `c` still
        // queued.
        hold.release_one();
        within("b on the writer", hold.until_arrived(2)).await;
        tokio::time::sleep(drain).await;
        assert!(scene.root.join("a").exists());
        assert!(!scene.root.join("b").exists());
        hold.release();
    };
    tokio::select! {
        biased;
        _ = &mut claiming => panic!("the claim was answered while landings were held"),
        () = landing => {}
    }
    let second = within("the claim", claiming).await;
    // Answered once the session had gone: everything it staged landed,
    // its spool empty, before the claimer could lock or scan.
    for (name, content) in files {
        assert_eq!(std::fs::read(scene.root.join(name)).unwrap(), content);
    }
    let spool = scene
        .server
        .state()
        .spool(&EntryId::parse(PROFILE).unwrap(), Side::B);
    assert_eq!(files_under(&spool), Vec::<PathBuf>::new());
    // The dead session let its lock go on the claim, not at its silence
    // limit: that is a minute off.
    within("lock", second.lock()).await.unwrap();
    within("unlock", second.unlock()).await.unwrap();
    within("close", second.close()).await.unwrap();
}
