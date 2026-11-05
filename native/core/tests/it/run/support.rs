//! Fixtures for the run tests: two replica roots and a state dir in a temp
//! dir, the pair's options, a run driven to its end with every event it
//! emitted, a remote side served over `tokio::io::duplex`, and [`Probe`] -
//! a real replica with a log of what was asked of it and a hook that can
//! fail or hold any call. No mock replicas: every probe wraps a real one.

use std::collections::BTreeMap;
use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use dsync_core::{
    ArchiveHeader, ArchiveStore, Body, BucketTicket, Decider, DigestTicket, DigestedScan, Landings,
    LinkError, Listing, LocalReplica, OpenedScan, Peek, Reading, RemoteReplica, Replica,
    ReplicaError, ReplicaServer, Run, RunEvent, RunReport, ServedReads, StateDir, Transport,
};
use dsync_domain::{
    Action, Archive, ArchiveCommit, Bucket, BucketCount, Command, EffectiveOptions, FileMeta,
    FileState, Flags, HostFacts, Location, LockFacts, Platform, Precondition, RelPath,
    ReplicaLocation, ReplicaSpec, RootFacts, RuleSet, RunFlags, ScanEntry, Side, SpoolSetting,
    Tuning, WriteStats,
};
use tempfile::TempDir;

use crate::cut_link::CutLink;
use tokio::sync::{Semaphore, mpsc};
use tokio::task::JoinHandle;

/// Every async test's own deadline: a few seconds, far above what any of
/// them takes.
pub const DEADLINE: Duration = Duration::from_secs(10);

pub async fn with_deadline<T>(label: &str, work: impl Future<Output = T>) -> T {
    tokio::time::timeout(DEADLINE, work)
        .await
        .unwrap_or_else(|_| panic!("{label} did not finish within {DEADLINE:?}"))
}

/// The run's event channel: small, so a test sees backpressure.
pub const EVENTS: usize = 8;

/// Sets `file`'s mtime an hour back, still distinct per call, so a scan
/// reads it long after its mtime and trusts size and mtime for it
/// (`dsync_domain::FileMeta::settled`), as it would a file of the user's
/// not touched in the last few seconds.
pub fn backdate(file: &Path) {
    let hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    fs::File::options()
        .write(true)
        .open(file)
        .unwrap()
        .set_modified(hour_ago)
        .unwrap();
}

pub fn path(text: &str) -> RelPath {
    RelPath::parse(text).unwrap()
}

/// Two replica roots, `a` and `b`, and the state dir both sides' archives,
/// locks and the run marker live in.
pub struct Site {
    dir: TempDir,
}

impl Site {
    pub fn new() -> Site {
        let site = Site {
            dir: tempfile::tempdir().unwrap(),
        };
        fs::create_dir(site.root(Side::A)).unwrap();
        fs::create_dir(site.root(Side::B)).unwrap();
        site
    }

    pub fn root(&self, side: Side) -> PathBuf {
        self.dir.path().join(side.to_string())
    }

    pub fn state(&self) -> StateDir {
        StateDir::new(self.dir.path().join("state"))
    }

    /// The ad hoc pair `a` `b`, no flags.
    pub fn options(&self) -> EffectiveOptions {
        self.options_with(Flags::default())
    }

    pub fn options_with(&self, flags: Flags) -> EffectiveOptions {
        let location = |side| {
            let raw = self.root(side).to_str().unwrap().to_owned();
            ReplicaLocation::new(Location::parse(&raw, Platform::HOST).unwrap(), None).unwrap()
        };
        let facts = HostFacts::new(Platform::HOST, None, [], "/".to_owned());
        let options = EffectiveOptions::for_ad_hoc(
            location(Side::A),
            location(Side::B),
            &RunFlags::validate(Command::Sync, flags).unwrap(),
            &facts,
            &[],
        )
        .unwrap();
        assert_eq!(options.replica(Side::A), &location(Side::A));
        options
    }

    pub fn spec(&self, side: Side) -> ReplicaSpec {
        ReplicaSpec {
            root: self.root(side).to_str().unwrap().to_owned(),
            kind: dsync_domain::RootKind::Folder,
            as_path: None,
            entry: self.options().entry_id,
            side,
            jobs: dsync_domain::Jobs::DEFAULT,
        }
    }

    pub fn replica(&self, side: Side) -> LocalReplica {
        self.replica_with(side, Tuning::DEFAULT)
    }

    pub fn replica_with(&self, side: Side, tuning: Tuning) -> LocalReplica {
        self.replica_spooling(side, tuning, SpoolSetting::Off)
    }

    /// [`Site::replica_with`], spooling as `spool` says.
    pub fn replica_spooling(
        &self,
        side: Side,
        tuning: Tuning,
        spool: SpoolSetting,
    ) -> LocalReplica {
        let spec = self.spec(side);
        LocalReplica::open(
            dsync_core::Root::new(spec.root, spec.kind, spec.as_path.clone()).unwrap(),
            self.state(),
            spec.entry,
            side,
            spec.jobs,
            tuning,
            dsync_core::LocalRules {
                symlinks: dsync_core::Symlinks::AsRuled,
                spool,
            },
        )
    }

    pub fn file(&self, side: Side, relative: &str) -> PathBuf {
        self.root(side).join(relative)
    }

    /// Writes `content` at `relative` on `side`, creating its folders, as
    /// a file written a while ago ([`backdate`]).
    pub fn put(&self, side: Side, relative: &str, content: impl AsRef<[u8]>) -> PathBuf {
        let file = self.file(side, relative);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, content).unwrap();
        backdate(&file);
        file
    }

    /// Writes `content` at `relative` on `side` with the mtime the write
    /// itself stamps: a file the next scan reads within its mtime's window
    /// (`dsync_domain::FileMeta::settled`).
    pub fn put_now(&self, side: Side, relative: &str, content: impl AsRef<[u8]>) -> PathBuf {
        let file = self.file(side, relative);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, content).unwrap();
        file
    }

    pub fn get(&self, side: Side, relative: &str) -> Option<Vec<u8>> {
        fs::read(self.file(side, relative)).ok()
    }

    pub fn exists(&self, side: Side, relative: &str) -> bool {
        self.file(side, relative).exists()
    }

    /// Every file under `side`'s root, relative path to content.
    pub fn tree(&self, side: Side) -> BTreeMap<String, Vec<u8>> {
        let mut tree = BTreeMap::new();
        collect(&self.root(side), &self.root(side), &mut tree);
        tree
    }

    pub fn log(&self, side: Side) -> PathBuf {
        self.state().archive_log(&self.options().entry_id, side)
    }

    /// `side`'s archive as the next run would read it off disk.
    pub fn archive(&self, side: Side) -> Archive {
        let spec = self.spec(side);
        let header = ArchiveHeader {
            entry_id: spec.entry,
            root_path: spec.root,
        };
        ArchiveStore::open(self.log(side), header, &Tuning::DEFAULT)
            .unwrap()
            .archive()
            .clone()
    }

    pub fn marker(&self) -> PathBuf {
        self.state().run_marker(&self.options().entry_id)
    }
}

fn collect(root: &Path, dir: &Path, into: &mut BTreeMap<String, Vec<u8>>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries {
        let entry = entry.unwrap();
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            collect(root, &entry.path(), into);
        } else if kind.is_file() {
            let relative = entry.path().strip_prefix(root).unwrap().to_owned();
            into.insert(
                relative.to_str().unwrap().replace('\\', "/"),
                fs::read(entry.path()).unwrap(),
            );
        }
    }
}

/// A run's report and every event it emitted, in order.
pub struct Finished {
    pub report: RunReport,
    pub events: Vec<RunEvent>,
}

impl Finished {
    pub fn exit_code(&self) -> u8 {
        self.report.outcome(None).exit_code()
    }

    pub fn errors(&self) -> Vec<&dsync_core::RunError> {
        self.events
            .iter()
            .filter_map(|event| match event {
                RunEvent::Error(error) => Some(error),
                _ => None,
            })
            .collect()
    }

    /// Each result's path and whether it succeeded, in report order.
    pub fn results(&self) -> Vec<(String, bool)> {
        self.events
            .iter()
            .filter_map(|event| match event {
                RunEvent::Result { action, outcome } => {
                    Some((action.path().as_str().to_owned(), outcome.is_ok()))
                }
                _ => None,
            })
            .collect()
    }

    /// A one-word name per event, for order assertions.
    pub fn kinds(&self) -> Vec<&'static str> {
        self.events.iter().map(kind).collect()
    }
}

pub fn kind(event: &RunEvent) -> &'static str {
    match event {
        RunEvent::Replicas { .. } => "replicas",
        RunEvent::ScanTally { .. } => "tally",
        RunEvent::Skipped { .. } => "skipped",
        RunEvent::Conflict(_) => "conflict",
        RunEvent::Plan { .. } => "plan",
        RunEvent::MassDelete { .. } => "massDelete",
        RunEvent::MassOverwrite { .. } => "massOverwrite",
        RunEvent::Action(_) => "action",
        RunEvent::Result { .. } => "result",
        RunEvent::Progress { .. } => "progress",
        RunEvent::Summary(_) => "summary",
        RunEvent::Error(_) => "error",
    }
}

/// Runs `a` against `b` to the end, collecting its events.
pub async fn run<A: Replica, B: Replica>(
    site: &Site,
    a: A,
    b: B,
    decider: &mut impl Decider,
) -> Finished {
    run_with(site, a, b, &site.options(), decider, Tuning::DEFAULT).await
}

pub async fn run_with<A: Replica, B: Replica>(
    site: &Site,
    a: A,
    b: B,
    options: &EffectiveOptions,
    decider: &mut impl Decider,
    tuning: Tuning,
) -> Finished {
    let (sender, mut receiver) = mpsc::channel(EVENTS);
    let collecting = tokio::spawn(async move {
        let mut events = Vec::new();
        while let Some(event) = receiver.recv().await {
            events.push(event);
        }
        events
    });
    let report = with_deadline(
        "the run",
        Run::new(sender, site.state(), tuning).execute(a, b, options, decider),
    )
    .await;
    Finished {
        report,
        events: with_deadline("the events", collecting).await.unwrap(),
    }
}

/// A batch sync of the site's two local replicas.
pub async fn sync(site: &Site) -> Finished {
    run(
        site,
        site.replica(Side::A),
        site.replica(Side::B),
        &mut dsync_core::BatchDecider,
    )
    .await
}

/// A decider that answers with a fixed list, and remembers being asked.
pub struct Answer {
    pub actions: Vec<Action>,
    pub asked: bool,
}

impl Decider for Answer {
    async fn decide<A: Replica, B: Replica>(
        &mut self,
        _: &dsync_domain::Plan,
        _: Peek<'_, A, B>,
    ) -> Vec<Action> {
        self.asked = true;
        self.actions.clone()
    }

    /// Its lists never delete enough to trip SPEC §10's guard.
    async fn confirm_deletes(&mut self, verdict: &dsync_domain::MassDelete) -> bool {
        panic!("an Answer was asked to confirm deletions: {verdict:?}")
    }

    /// Nor overwrite enough to trip the overwrite guard.
    async fn confirm_overwrites(&mut self, verdict: &dsync_domain::MassOverwrite) -> bool {
        panic!("an Answer was asked to confirm overwrites: {verdict:?}")
    }
}

/// One call on a [`Probe`], as the run made it.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Call {
    Hello,
    Lock,
    Unlock,
    CreateRoot,
    Scan,
    Read(String),
    Write(String),
    Stage(String),
    /// Not a call: a stage answered, staged or failed.
    Staged(String),
    TakeLanded,
    Delete(String),
    RemoveEmptyDirs(String),
    Commit(Vec<ArchiveCommit>),
    Compact,
    Close,
}

/// What a hook does to a call.
pub enum Fault {
    Fail(ReplicaError),
    /// Waits for the gate to open (closed, or given a permit) first.
    Hold(Arc<Semaphore>),
    /// Lets a write land, then reports `size` for it.
    Report(u64),
    /// Lets the call through, then waits for the gate before answering.
    HoldAnswer(Arc<Semaphore>),
}

pub type Hook = Arc<dyn Fn(&Call) -> Option<Fault> + Send + Sync>;

/// A real replica, logging each call before making it and asking `hook`
/// first whether to fail or hold it.
pub struct Probe<R> {
    inner: R,
    log: Log,
    hook: Hook,
}

/// A probe's call log, kept by the test after the probe moves into a run.
#[derive(Clone)]
pub struct Log {
    calls: Arc<Mutex<Vec<Call>>>,
    /// The number of calls logged, for [`Log::until`].
    logged: Arc<tokio::sync::watch::Sender<usize>>,
}

impl Log {
    fn new() -> Log {
        Log {
            calls: Arc::default(),
            logged: Arc::new(tokio::sync::watch::Sender::new(0)),
        }
    }

    fn push(&self, call: Call) {
        let mut calls = lock(&self.calls);
        calls.push(call);
        self.logged.send_replace(calls.len());
    }

    pub fn calls(&self) -> Vec<Call> {
        lock(&self.calls).clone()
    }

    /// How many logged calls `wanted` picks.
    pub fn count(&self, wanted: impl Fn(&Call) -> bool) -> usize {
        lock(&self.calls).iter().filter(|call| wanted(call)).count()
    }

    /// Waits until `wanted` picks at least `count` logged calls.
    pub async fn until(&self, count: usize, wanted: impl Fn(&Call) -> bool) {
        let mut logged = self.logged.subscribe();
        while self.count(&wanted) < count {
            let _ = logged.changed().await;
        }
    }

    pub fn commits(&self) -> Vec<Vec<ArchiveCommit>> {
        self.calls()
            .into_iter()
            .filter_map(|call| match call {
                Call::Commit(batch) => Some(batch),
                _ => None,
            })
            .collect()
    }
}

impl<R: Replica> Probe<R> {
    pub fn new(inner: R) -> (Probe<R>, Log) {
        Probe::with_hook(inner, Arc::new(|_: &Call| None))
    }

    pub fn with_hook(inner: R, hook: Hook) -> (Probe<R>, Log) {
        let log = Log::new();
        (
            Probe {
                inner,
                log: log.clone(),
                hook,
            },
            log,
        )
    }

    /// Logs `call`; `Err` when the hook fails it, and the fault still to
    /// apply once the call is made (`Report`, `HoldAnswer`), if any.
    async fn enter(&self, call: Call) -> Result<Option<Fault>, ReplicaError> {
        let fault = (self.hook)(&call);
        self.log.push(call);
        match fault {
            None => Ok(None),
            Some(Fault::Fail(error)) => Err(error),
            Some(Fault::Hold(gate)) => {
                let _ = gate.acquire().await;
                Ok(None)
            }
            after => Ok(after),
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl<R: Replica> Replica for Probe<R> {
    async fn hello(&self) -> Result<RootFacts, ReplicaError> {
        self.enter(Call::Hello).await?;
        self.inner.hello().await
    }

    async fn lock(&self) -> Result<LockFacts, ReplicaError> {
        self.enter(Call::Lock).await?;
        self.inner.lock().await
    }

    async fn unlock(&self) -> Result<(), ReplicaError> {
        self.enter(Call::Unlock).await?;
        self.inner.unlock().await
    }

    async fn create_root(&self) -> Result<(), ReplicaError> {
        self.enter(Call::CreateRoot).await?;
        self.inner.create_root().await
    }

    async fn open_scan(&self, rules: &RuleSet) -> Result<OpenedScan, ReplicaError> {
        self.enter(Call::Scan).await?;
        self.inner.open_scan(rules).await
    }

    async fn scan_digests(
        &self,
        ticket: DigestTicket,
        count: BucketCount,
        peer_changed: Listing<RelPath>,
    ) -> Result<DigestedScan, ReplicaError> {
        self.inner.scan_digests(ticket, count, peer_changed).await
    }

    async fn scan_buckets(
        &self,
        ticket: &BucketTicket,
        buckets: &[Bucket],
    ) -> Result<Vec<ScanEntry>, ReplicaError> {
        self.inner.scan_buckets(ticket, buckets).await
    }

    async fn read(&self, path: &RelPath) -> Result<Reading, ReplicaError> {
        self.enter(Call::Read(path.as_str().to_owned())).await?;
        self.inner.read(path).await
    }

    async fn write(
        &self,
        path: &RelPath,
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> Result<FileMeta, ReplicaError> {
        let after = self.enter(Call::Write(path.as_str().to_owned())).await?;
        let landed = self.inner.write(path, body, source, expect).await?;
        let size = match after {
            Some(Fault::Report(size)) => size,
            _ => landed.size,
        };
        Ok(FileMeta { size, ..landed })
    }

    async fn stage(
        &self,
        path: &RelPath,
        body: Body,
        source: FileState,
        expect: Precondition,
    ) -> Result<(), ReplicaError> {
        let after = self.enter(Call::Stage(path.as_str().to_owned())).await?;
        let staged = self.inner.stage(path, body, source, expect).await;
        self.log.push(Call::Staged(path.as_str().to_owned()));
        if let Some(Fault::HoldAnswer(gate)) = after {
            let _ = gate.acquire().await;
        }
        staged
    }

    async fn take_landed(&self) -> Result<Landings, ReplicaError> {
        self.enter(Call::TakeLanded).await?;
        self.inner.take_landed().await
    }

    async fn settle(&self) {
        self.inner.settle().await;
    }

    async fn delete(&self, path: &RelPath, expect: Precondition) -> Result<(), ReplicaError> {
        self.enter(Call::Delete(path.as_str().to_owned())).await?;
        self.inner.delete(path, expect).await
    }

    async fn remove_empty_dirs(&self, path: &RelPath) -> Result<(), ReplicaError> {
        self.enter(Call::RemoveEmptyDirs(path.as_str().to_owned()))
            .await?;
        self.inner.remove_empty_dirs(path).await
    }

    async fn commit(&self, batch: Vec<ArchiveCommit>) -> Result<(), ReplicaError> {
        self.enter(Call::Commit(batch.clone())).await?;
        self.inner.commit(batch).await
    }

    async fn compact(&self) -> Result<(), ReplicaError> {
        self.enter(Call::Compact).await?;
        self.inner.compact().await
    }

    async fn close(self) -> Result<(), ReplicaError> {
        self.log.push(Call::Close);
        self.inner.close().await
    }

    fn write_stats(&self) -> Option<WriteStats> {
        self.inner.write_stats()
    }

    fn spool_drain(&self) -> Option<dsync_core::SpoolDrain> {
        self.inner.spool_drain()
    }

    fn base(&self) -> &std::path::Path {
        self.inner.base()
    }
}

/// A failure the run treats as the action's own, not the run's.
pub fn refused() -> ReplicaError {
    ReplicaError::Refused("injected".into())
}

/// A failure that ends the run.
pub fn link_down() -> ReplicaError {
    ReplicaError::Link(LinkError::Closed)
}

/// Serves one session over `stream`, opening what the client's `hello`
/// names with `site`'s state dir: what `dsync agent` does.
pub fn serve<S>(site: &Site, stream: S) -> JoinHandle<Result<(), LinkError>>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    serve_with(site, stream, Tuning::DEFAULT)
}

/// [`serve`], with `tuning` for the server and the replica it opens.
pub fn serve_with<S>(site: &Site, stream: S, tuning: Tuning) -> JoinHandle<Result<(), LinkError>>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    serve_spooling(site, Transport::split(stream), tuning, SpoolSetting::Off)
}

/// [`serve_with`] over `transport`, the replica it opens spooling as
/// `spool` says.
pub fn serve_spooling<R, W>(
    site: &Site,
    transport: Transport<R, W>,
    tuning: Tuning,
    spool: SpoolSetting,
) -> JoinHandle<Result<(), LinkError>>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
    W: tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let state = site.state();
    let server = ReplicaServer::new(
        move |spec: ReplicaSpec| {
            let state = state.clone();
            async move {
                Ok::<_, ReplicaError>(LocalReplica::open(
                    dsync_core::Root::new(spec.root, spec.kind, spec.as_path.clone()).unwrap(),
                    state,
                    spec.entry,
                    spec.side,
                    spec.jobs,
                    tuning,
                    dsync_core::LocalRules {
                        symlinks: dsync_core::Symlinks::AsRuled,
                        spool,
                    },
                ))
            }
        },
        tuning,
        ServedReads::new(&tuning),
    );
    tokio::spawn(async move { server.serve(transport).await })
}

/// The replica `spec` names, opened with `tuning` and spooling as
/// `spool` says, served over loopback TCP through a relay the test can
/// cut; the remote replica talking to it, and the session.
pub async fn served_through_link(
    site: &Site,
    spec: ReplicaSpec,
    tuning: Tuning,
    spool: SpoolSetting,
) -> (RemoteReplica, JoinHandle<Result<(), LinkError>>, CutLink) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let link = CutLink::to(listener.local_addr().unwrap()).await;
    let (accepted, far) = tokio::sync::oneshot::channel();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let _ = accepted.send(stream);
    });
    let near = tokio::net::TcpStream::connect(link.at).await.unwrap();
    let (reader, writer) = with_deadline("accept", far).await.unwrap().into_split();
    let serving = serve_spooling(site, Transport::new(reader, writer), tuning, spool);
    let (reader, writer) = near.into_split();
    let replica = with_deadline(
        "connect",
        RemoteReplica::connect(Transport::new(reader, writer), spec, &Tuning::DEFAULT),
    )
    .await
    .unwrap();
    (replica, serving, link)
}

/// The duplex buffer: small next to a body's credit, so backpressure
/// reaches the far side's writer as it would over a socket.
const DUPLEX_BYTES: usize = 64 * 1024;

/// `side` of `site` served by a [`ReplicaServer`] in this process, and the
/// remote replica talking to it.
pub async fn served(site: &Site, side: Side) -> (RemoteReplica, JoinHandle<Result<(), LinkError>>) {
    served_with(site, side, Tuning::DEFAULT).await
}

/// [`served`], with `tuning` on both ends of the connection and for the
/// served replica.
pub async fn served_with(
    site: &Site,
    side: Side,
    tuning: Tuning,
) -> (RemoteReplica, JoinHandle<Result<(), LinkError>>) {
    let (near, far) = tokio::io::duplex(DUPLEX_BYTES);
    let serving = serve_with(site, far, tuning);
    let replica = with_deadline(
        "connect",
        RemoteReplica::connect(Transport::split(near), site.spec(side), &tuning),
    )
    .await
    .unwrap();
    (replica, serving)
}
