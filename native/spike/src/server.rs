//! The receiving side: accepts one connection from an admitted peer and
//! writes the tree it sends under a root directory.
//!
//! The socket is read on the async runtime; files are written by a pool of
//! blocking writer threads (writer.rs), each file whole by one writer, taken
//! in arrival order, so a file's creation, content and mtime stay ordered
//! while the next files' headers and bytes keep arriving.

use std::fs;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, ensure};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

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
use crate::write_stats::WriteStats;
use crate::writer::WriterPool;

pub struct ServeOptions {
    pub root: PathBuf,
    /// 0 for any free port; [ServeEvent::Ready] says which.
    pub port: u16,
    pub allow: PeerPin,
    /// Blocking file-writer threads, at least one.
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
    pub writes: WriteStats,
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
    let pool = WriterPool::start(options.writers, done_tx);

    let mut reader = BufReader::with_capacity(IO_CHUNK, stream);
    let received = receive(&mut reader, &options.root, &pool).await;
    // A writer's own error explains a failed send better than the send does.
    let writes = pool.finish().await?;
    received?;
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
    Ok(Received {
        peer,
        metrics,
        writes,
    })
}

/// Reads frames to the end of the tree, handing each file to the writers.
/// Stops early, with no error of its own, once a writer has failed.
async fn receive<R: AsyncReadExt + Unpin>(
    reader: &mut R,
    root: &Path,
    pool: &WriterPool,
) -> anyhow::Result<()> {
    wire::read_magic(reader).await?;
    loop {
        let header = match wire::read_frame(reader).await? {
            Frame::End => return Ok(()),
            Frame::File(header) => header,
        };
        if pool.failed() {
            return Ok(());
        }
        let mut remaining = header.size;
        let file = pool.submit(root, header).await?;
        while remaining > 0 {
            let n = remaining.min(IO_CHUNK as u64) as usize;
            let mut chunk = vec![0u8; n];
            reader.read_exact(&mut chunk).await?;
            file.send(chunk).await?;
            remaining -= n as u64;
        }
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
