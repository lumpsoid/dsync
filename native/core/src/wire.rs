//! The transfer's framing, big-endian throughout.
//!
//! Client to server, once: [MAGIC]. Then per file, back to back with no
//! per-file acknowledgement:
//!   tag 0x01, u16 path length, path (UTF-8, `/`-separated),
//!   u64 size, i64 mtime seconds since the epoch, u32 mtime nanoseconds,
//!   then exactly `size` content bytes.
//! Then tag 0x00: the end of the tree.
//!
//! Server to client, once every file is on disk: [Summary], u64 files and
//! u64 bytes written.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{bail, ensure};
use tokio::io::{AsyncRead, AsyncReadExt};

use crate::rel_path::RelPath;

pub const MAGIC: [u8; 4] = *b"dsR1";
const TAG_END: u8 = 0;
const TAG_FILE: u8 = 1;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct FileHeader {
    pub path: RelPath,
    pub size: u64,
    pub mtime: SystemTime,
}

#[derive(PartialEq, Eq, Debug)]
pub enum Frame {
    File(FileHeader),
    End,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Summary {
    pub files: u64,
    pub bytes: u64,
}

impl FileHeader {
    pub fn encode(&self) -> anyhow::Result<Vec<u8>> {
        let path = self.path.as_str().as_bytes();
        let path_len = u16::try_from(path.len())?;
        let (seconds, nanos) = match self.mtime.duration_since(UNIX_EPOCH) {
            Ok(after) => (after.as_secs() as i64, after.subsec_nanos()),
            Err(before) => {
                let before = before.duration();
                let mut seconds = -(before.as_secs() as i64);
                let mut nanos = before.subsec_nanos();
                if nanos > 0 {
                    seconds -= 1;
                    nanos = 1_000_000_000 - nanos;
                }
                (seconds, nanos)
            }
        };
        let mut out = Vec::with_capacity(1 + 2 + path.len() + 8 + 8 + 4);
        out.push(TAG_FILE);
        out.extend_from_slice(&path_len.to_be_bytes());
        out.extend_from_slice(path);
        out.extend_from_slice(&self.size.to_be_bytes());
        out.extend_from_slice(&seconds.to_be_bytes());
        out.extend_from_slice(&nanos.to_be_bytes());
        Ok(out)
    }
}

pub fn encode_end() -> [u8; 1] {
    [TAG_END]
}

impl Summary {
    pub fn encode(&self) -> [u8; 16] {
        let mut out = [0u8; 16];
        out[..8].copy_from_slice(&self.files.to_be_bytes());
        out[8..].copy_from_slice(&self.bytes.to_be_bytes());
        out
    }

    pub async fn read<R: AsyncRead + Unpin>(from: &mut R) -> anyhow::Result<Self> {
        Ok(Summary {
            files: from.read_u64().await?,
            bytes: from.read_u64().await?,
        })
    }
}

pub async fn read_magic<R: AsyncRead + Unpin>(from: &mut R) -> anyhow::Result<()> {
    let mut magic = [0u8; 4];
    from.read_exact(&mut magic).await?;
    ensure!(magic == MAGIC, "not a dsync-rs transfer (magic {magic:?})");
    Ok(())
}

/// The next frame's header; the caller then reads the file's content.
pub async fn read_frame<R: AsyncRead + Unpin>(from: &mut R) -> anyhow::Result<Frame> {
    match from.read_u8().await? {
        TAG_END => Ok(Frame::End),
        TAG_FILE => {
            let path_len = from.read_u16().await? as usize;
            let mut path = vec![0u8; path_len];
            from.read_exact(&mut path).await?;
            let path = RelPath::parse(std::str::from_utf8(&path)?)?;
            let size = from.read_u64().await?;
            let seconds = from.read_i64().await?;
            let nanos = from.read_u32().await?;
            ensure!(nanos < 1_000_000_000, "bad mtime nanoseconds {nanos}");
            let mtime = if seconds >= 0 {
                UNIX_EPOCH + Duration::new(seconds as u64, nanos)
            } else {
                UNIX_EPOCH - Duration::from_secs(seconds.unsigned_abs())
                    + Duration::from_nanos(nanos as u64)
            };
            Ok(Frame::File(FileHeader { path, size, mtime }))
        }
        tag => bail!("unknown frame tag {tag}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn headers_round_trip_including_pre_epoch_mtimes() {
        for mtime in [
            UNIX_EPOCH + Duration::new(1_700_000_000, 123_456_789),
            UNIX_EPOCH - Duration::new(5, 250_000_000),
            UNIX_EPOCH,
        ] {
            let header = FileHeader {
                path: RelPath::parse("d/f.bin").unwrap(),
                size: 13 << 10,
                mtime,
            };
            let mut bytes = header.encode().unwrap();
            bytes.extend_from_slice(&encode_end());
            let mut reader = bytes.as_slice();
            assert_eq!(read_frame(&mut reader).await.unwrap(), Frame::File(header));
            assert_eq!(read_frame(&mut reader).await.unwrap(), Frame::End);
        }
    }

    #[tokio::test]
    async fn a_path_that_escapes_the_root_is_refused_on_read() {
        let mut bytes = vec![TAG_FILE, 0, 5];
        bytes.extend_from_slice(b"../x0");
        bytes.extend_from_slice(&[0; 20]);
        assert!(read_frame(&mut bytes.as_slice()).await.is_err());
    }

    #[tokio::test]
    async fn summaries_round_trip() {
        let summary = Summary {
            files: 3,
            bytes: 1 << 40,
        };
        let bytes = summary.encode();
        assert_eq!(Summary::read(&mut bytes.as_slice()).await.unwrap(), summary);
    }
}
