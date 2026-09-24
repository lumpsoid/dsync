//! The sending side: walks a local directory and sends every regular file
//! under it on one connection, pipelined: headers and bytes go out back to
//! back, and the only acknowledgement is the server's summary at the end.
//!
//! Files are read on a blocking thread, a chunk at a time, into a bounded
//! queue the async side drains into the TLS stream, so disk reads and
//! encryption overlap.

use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, ensure};
use tokio::io::{AsyncWriteExt, BufWriter};
use tokio::net::TcpStream;
use tokio::sync::mpsc;

use crate::IO_CHUNK;
use crate::cpu::process_cpu;
use crate::device_id::DeviceId;
use crate::identity::Identity;
use crate::metrics::TransferMetrics;
use crate::peer_pin::PeerPin;
use crate::rel_path::RelPath;
use crate::tls;
use crate::wire::{self, FileHeader, Summary};

/// Chunks read ahead of the socket.
const READ_AHEAD: usize = 16;

pub struct PushOptions {
    pub dir: PathBuf,
    pub host: String,
    pub port: u16,
    pub pin: PeerPin,
}

pub struct PushReport {
    pub server: DeviceId,
    /// Measured from the end of the handshake to the server's summary, so
    /// it covers the server's last write too.
    pub metrics: TransferMetrics,
}

pub async fn push(identity: &Identity, options: PushOptions) -> anyhow::Result<PushReport> {
    let dir = options.dir.clone();
    let files = tokio::task::spawn_blocking(move || walk(&dir)).await??;
    let expected = Summary {
        files: files.len() as u64,
        bytes: files.iter().map(|f| f.header.size).sum(),
    };

    let connector = tls::connector(identity, options.pin)?;
    let tcp = TcpStream::connect((options.host.as_str(), options.port))
        .await
        .with_context(|| format!("connecting to {}:{}", options.host, options.port))?;
    tcp.set_nodelay(true)?;
    let stream = connector
        .connect(tls::server_name(), tcp)
        .await
        .context("TLS handshake")?;
    let server = tls::peer_device_id(stream.get_ref().1.peer_certificates())?;

    let start = Instant::now();
    let cpu_start = process_cpu();
    let (chunks_tx, mut chunks) = mpsc::channel::<Vec<u8>>(READ_AHEAD);
    let reader = tokio::task::spawn_blocking(move || read_files(files, chunks_tx));

    let mut writer = BufWriter::with_capacity(IO_CHUNK, stream);
    writer.write_all(&wire::MAGIC).await?;
    while let Some(chunk) = chunks.recv().await {
        writer.write_all(&chunk).await?;
    }
    reader.await??;
    writer.write_all(&wire::encode_end()).await?;
    writer.flush().await?;

    let mut stream = writer.into_inner();
    let summary = Summary::read(&mut stream)
        .await
        .context("reading the server's summary")?;
    let wall = start.elapsed();
    ensure!(
        summary == expected,
        "server wrote {summary:?}, sent {expected:?}"
    );
    let cpu = match (cpu_start, process_cpu()) {
        (Some(from), Some(to)) => Some(to.saturating_sub(from)),
        _ => None,
    };
    let _ = stream.shutdown().await;
    Ok(PushReport {
        server,
        metrics: TransferMetrics {
            bytes: summary.bytes,
            files: summary.files,
            wall,
            cpu,
        },
    })
}

struct LocalFile {
    source: PathBuf,
    header: FileHeader,
}

/// Every regular file under [root], in path order; symlinks and other
/// special files are skipped.
fn walk(root: &Path) -> anyhow::Result<Vec<LocalFile>> {
    let mut files = Vec::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        for entry in fs::read_dir(&dir).with_context(|| format!("listing {}", dir.display()))? {
            let entry = entry?;
            let meta = entry.metadata()?;
            let source = entry.path();
            if meta.is_dir() {
                dirs.push(source);
            } else if meta.is_file() {
                let path = RelPath::from_local(root, &source)?;
                let header = FileHeader {
                    path,
                    size: meta.len(),
                    mtime: meta.modified()?,
                };
                files.push(LocalFile { source, header });
            }
        }
    }
    files.sort_by(|a, b| a.header.path.as_str().cmp(b.header.path.as_str()));
    Ok(files)
}

/// Frames every file into [out] as [IO_CHUNK]-sized chunks: each file's
/// header, then its content. Chunks run across file boundaries, so many
/// small files share one chunk and one socket write.
fn read_files(files: Vec<LocalFile>, out: mpsc::Sender<Vec<u8>>) -> anyhow::Result<()> {
    let mut chunk = Vec::with_capacity(IO_CHUNK);
    for file in files {
        chunk.extend_from_slice(&file.header.encode()?);
        let mut source = File::open(&file.source)
            .with_context(|| format!("opening {}", file.source.display()))?;
        let mut remaining = file.header.size;
        while remaining > 0 {
            if chunk.len() >= IO_CHUNK {
                out.blocking_send(std::mem::replace(&mut chunk, Vec::with_capacity(IO_CHUNK)))?;
            }
            let n = remaining.min((IO_CHUNK - chunk.len()) as u64) as usize;
            let at = chunk.len();
            chunk.resize(at + n, 0);
            source
                .read_exact(&mut chunk[at..])
                .with_context(|| format!("reading {} (did it shrink?)", file.source.display()))?;
            remaining -= n as u64;
        }
    }
    if !chunk.is_empty() {
        out.blocking_send(chunk)?;
    }
    Ok(())
}
