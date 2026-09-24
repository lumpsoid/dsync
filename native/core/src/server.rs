//! The receiving side: accepts one connection from an admitted peer and
//! writes the tree it sends under a root directory.
//!
//! The socket is read on the async runtime; files are written by a pool of
//! blocking writer threads, each file whole to one writer, round robin, so a
//! file's creation, content and mtime stay ordered while the next files'
//! headers and bytes keep arriving. Each writer's queue is bounded, which is
//! what pushes back on the sender when the disk is the slower side.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::Write;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime};

use anyhow::{Context, anyhow, ensure};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::IO_CHUNK;
use crate::cpu::process_cpu;
use crate::device_id::DeviceId;
use crate::identity::Identity;
use crate::metrics::TransferMetrics;
use crate::peer_pin::PeerPin;
use crate::rel_path::RelPath;
use crate::throttle::{PROGRESS_INTERVAL, Throttle};
use crate::tls;
use crate::wire::{self, Frame, Summary};

/// Writer threads when the caller does not say.
pub const DEFAULT_WRITERS: usize = 4;

/// Chunks queued per writer before the socket reader waits on it.
const WRITER_QUEUE: usize = 8;

pub struct ServeOptions {
    pub root: PathBuf,
    /// 0 for any free port; [ServeEvent::Ready] says which.
    pub port: u16,
    pub allow: PeerPin,
    pub writers: usize,
}

#[derive(Debug)]
pub enum ServeEvent {
    /// Listening; the one connection has not come yet.
    Ready { port: u16, device_id: DeviceId },
    /// A peer the pin admits has connected.
    Connected { peer: DeviceId },
    /// One file is fully on disk, mtime set.
    FileDone { path: RelPath, bytes: u64 },
    /// Files and bytes on disk so far, at most one per [PROGRESS_INTERVAL].
    Progress { files: u64, bytes: u64 },
}

/// One finished transfer: who sent it, and what it took from the end of the
/// handshake to the last file on disk.
#[derive(Debug)]
pub struct Received {
    pub peer: DeviceId,
    pub metrics: TransferMetrics,
}

/// Serves one transfer into `options.root`. Events go to [events] as they
/// happen; a closed receiver is not an error.
pub async fn serve(
    identity: &Identity,
    options: ServeOptions,
    events: mpsc::UnboundedSender<ServeEvent>,
) -> anyhow::Result<Received> {
    ensure!(options.writers > 0, "at least one writer");
    let acceptor = tls::acceptor(identity, options.allow)?;
    let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::UNSPECIFIED, options.port)))
        .await
        .with_context(|| format!("binding port {}", options.port))?;
    let port = listener.local_addr()?.port();
    let _ = events.send(ServeEvent::Ready {
        port,
        device_id: identity.device_id(),
    });

    let (tcp, _) = listener.accept().await?;
    drop(listener);
    tcp.set_nodelay(true)?;
    let stream = acceptor.accept(tcp).await.context("TLS handshake")?;
    let peer = tls::peer_device_id(stream.get_ref().1.peer_certificates())?;
    let _ = events.send(ServeEvent::Connected { peer: peer.clone() });

    let start = Instant::now();
    let cpu_start = process_cpu();
    fs::create_dir_all(&options.root)
        .with_context(|| format!("creating {}", options.root.display()))?;

    let (done_tx, done_rx) = mpsc::unbounded_channel();
    let tally = tokio::spawn(tally(done_rx, events));
    let mut pool = WriterPool::start(options.writers, &done_tx);
    drop(done_tx);

    let mut reader = BufReader::with_capacity(IO_CHUNK, stream);
    let received = receive(&mut reader, &options.root, &mut pool).await;
    // A writer's own error explains a failed send better than the send does.
    let written = pool.finish().await;
    received?;
    written?;
    let summary = tally.await?;
    let wall = start.elapsed();
    let cpu = match (cpu_start, process_cpu()) {
        (Some(from), Some(to)) => Some(to.saturating_sub(from)),
        _ => None,
    };

    let mut stream = reader.into_inner();
    stream.write_all(&summary.encode()).await?;
    stream.shutdown().await?;
    let metrics = TransferMetrics {
        bytes: summary.bytes,
        files: summary.files,
        wall,
        cpu,
    };
    Ok(Received { peer, metrics })
}

/// Reads frames to the end of the tree, handing each file to a writer.
async fn receive<R: AsyncReadExt + Unpin>(
    reader: &mut R,
    root: &Path,
    pool: &mut WriterPool,
) -> anyhow::Result<()> {
    wire::read_magic(reader).await?;
    loop {
        let header = match wire::read_frame(reader).await? {
            Frame::End => return Ok(()),
            Frame::File(header) => header,
        };
        let writer = pool.next();
        let target = header.path.under(root);
        writer
            .send(Job::Open {
                target,
                path: header.path,
            })
            .await?;
        let mut remaining = header.size;
        while remaining > 0 {
            let n = remaining.min(IO_CHUNK as u64) as usize;
            let mut chunk = vec![0u8; n];
            reader.read_exact(&mut chunk).await?;
            writer.send(Job::Write(chunk)).await?;
            remaining -= n as u64;
        }
        writer
            .send(Job::Close {
                mtime: header.mtime,
                bytes: header.size,
            })
            .await?;
    }
}

/// Counts finished files into progress events; the totals once every writer
/// is done.
async fn tally(
    mut done: mpsc::UnboundedReceiver<(RelPath, u64)>,
    events: mpsc::UnboundedSender<ServeEvent>,
) -> Summary {
    let mut summary = Summary { files: 0, bytes: 0 };
    let mut throttle = Throttle::new(PROGRESS_INTERVAL);
    while let Some((path, bytes)) = done.recv().await {
        summary.files += 1;
        summary.bytes += bytes;
        let _ = events.send(ServeEvent::FileDone { path, bytes });
        if throttle.pass(Instant::now()) {
            let _ = events.send(ServeEvent::Progress {
                files: summary.files,
                bytes: summary.bytes,
            });
        }
    }
    summary
}

enum Job {
    Open { target: PathBuf, path: RelPath },
    Write(Vec<u8>),
    Close { mtime: SystemTime, bytes: u64 },
}

struct Writer {
    jobs: mpsc::Sender<Job>,
    thread: JoinHandle<anyhow::Result<()>>,
}

impl Writer {
    async fn send(&self, job: Job) -> anyhow::Result<()> {
        self.jobs
            .send(job)
            .await
            .map_err(|_| anyhow!("a writer stopped early"))
    }
}

struct WriterPool {
    writers: Vec<Writer>,
    turn: usize,
}

impl WriterPool {
    fn start(count: usize, done: &mpsc::UnboundedSender<(RelPath, u64)>) -> Self {
        let writers = (0..count)
            .map(|_| {
                let (jobs, queue) = mpsc::channel(WRITER_QUEUE);
                let done = done.clone();
                let thread = tokio::task::spawn_blocking(move || write_files(queue, done));
                Writer { jobs, thread }
            })
            .collect();
        WriterPool { writers, turn: 0 }
    }

    /// The writer the next file goes to.
    fn next(&mut self) -> &Writer {
        let writer = &self.writers[self.turn];
        self.turn = (self.turn + 1) % self.writers.len();
        writer
    }

    /// Closes every queue and waits for the writers to drain them.
    async fn finish(self) -> anyhow::Result<()> {
        let mut first_error = None;
        for Writer { jobs, thread } in self.writers {
            drop(jobs);
            if let Err(e) = thread.await.map_err(anyhow::Error::from).and_then(|r| r) {
                first_error.get_or_insert(e);
            }
        }
        first_error.map_or(Ok(()), Err)
    }
}

/// One writer thread: runs its queue's jobs until the queue closes.
fn write_files(
    mut queue: mpsc::Receiver<Job>,
    done: mpsc::UnboundedSender<(RelPath, u64)>,
) -> anyhow::Result<()> {
    let mut made_dirs = HashSet::new();
    let mut open: Option<(File, RelPath)> = None;
    while let Some(job) = queue.blocking_recv() {
        match job {
            Job::Open { target, path } => {
                if let Some(parent) = target.parent()
                    && !made_dirs.contains(parent)
                {
                    fs::create_dir_all(parent)
                        .with_context(|| format!("creating {}", parent.display()))?;
                    made_dirs.insert(parent.to_path_buf());
                }
                let file = File::create(&target)
                    .with_context(|| format!("creating {}", target.display()))?;
                open = Some((file, path));
            }
            Job::Write(chunk) => {
                let (file, path) = open.as_mut().ok_or_else(|| anyhow!("write with no file"))?;
                file.write_all(&chunk)
                    .with_context(|| format!("writing {path}"))?;
            }
            Job::Close { mtime, bytes } => {
                let (file, path) = open.take().ok_or_else(|| anyhow!("close with no file"))?;
                file.set_modified(mtime)
                    .with_context(|| format!("setting mtime of {path}"))?;
                drop(file);
                let _ = done.send((path, bytes));
            }
        }
    }
    Ok(())
}
