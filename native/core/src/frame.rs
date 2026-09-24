//! The unit of the replica protocol on the byte stream (plan D5): a nine
//! byte header - `kind` (u8), request `id` (u32, big-endian), payload
//! `length` (u32, big-endian) - then the payload.
//!
//! Control payloads (requests, replies, a body's failure) are postcard;
//! a body's bytes travel raw. Id 0 belongs to no request: the version
//! frames and heartbeats, which are properties of the connection.

use std::io;

use std::pin::Pin;
use std::task::{Context, Poll, Waker};

use tokio::io::{AsyncBufRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub(crate) const HEADER_BYTES: usize = 9;

/// The largest payload a frame may announce. Far above any real one - a
/// scan reply for a million-file tree is a few tens of MiB - and there so a
/// corrupt or hostile length is refused rather than trusted. The payload is
/// never allocated up front at the announced size either.
pub(crate) const MAX_PAYLOAD_BYTES: u32 = 512 * 1024 * 1024;

/// How much of an undecodable stream an error keeps: enough to recognise a
/// login banner or an error page, and no more.
pub(crate) const QUOTED_BYTES: usize = 256;

/// The id of a frame that answers to no request.
pub(crate) const NO_REQUEST: u32 = 0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Kind {
    /// The version handshake, the first frame each side sends.
    Version,
    /// A postcard request; opens the exchange its id names.
    Request,
    /// A postcard reply to the request its id names.
    Reply,
    /// A body's raw bytes.
    Chunk,
    /// A body's end: everything before it is the whole body.
    End,
    /// A body's failure in place of its end: a postcard [`crate::wire::WireIo`].
    Fail,
    /// A liveness tick: empty, never answered, dropped by every reader.
    Heartbeat,
}

impl Kind {
    const ALL: [Kind; 7] = [
        Kind::Version,
        Kind::Request,
        Kind::Reply,
        Kind::Chunk,
        Kind::End,
        Kind::Fail,
        Kind::Heartbeat,
    ];

    fn byte(self) -> u8 {
        match self {
            Kind::Version => 0x01,
            Kind::Request => 0x02,
            Kind::Reply => 0x03,
            Kind::Chunk => 0x04,
            Kind::End => 0x05,
            Kind::Fail => 0x06,
            Kind::Heartbeat => 0x07,
        }
    }

    fn from_byte(byte: u8) -> Option<Kind> {
        Kind::ALL.into_iter().find(|kind| kind.byte() == byte)
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub(crate) struct Frame {
    pub kind: Kind,
    pub id: u32,
    pub payload: Vec<u8>,
}

/// Why the byte stream is not frames.
#[derive(Debug)]
pub(crate) enum FrameError {
    Io(io::Error),
    /// Not this protocol's framing, with the first bytes that said so
    /// (at most [`QUOTED_BYTES`]).
    Undecodable {
        reason: &'static str,
        received: Vec<u8>,
        truncated: bool,
    },
}

impl Frame {
    pub fn new(kind: Kind, id: u32, payload: Vec<u8>) -> Frame {
        Frame { kind, id, payload }
    }

    pub fn heartbeat() -> Frame {
        Frame::new(Kind::Heartbeat, NO_REQUEST, Vec::new())
    }

    pub fn header(&self) -> [u8; HEADER_BYTES] {
        let length = u32::try_from(self.payload.len()).expect("a frame payload fits in a u32");
        let mut header = [0; HEADER_BYTES];
        header[0] = self.kind.byte();
        header[1..5].copy_from_slice(&self.id.to_be_bytes());
        header[5..9].copy_from_slice(&length.to_be_bytes());
        header
    }

    /// Header and payload, as written.
    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(HEADER_BYTES + self.payload.len());
        bytes.extend_from_slice(&self.header());
        bytes.extend_from_slice(&self.payload);
        bytes
    }

    /// Writes this frame; the caller flushes.
    pub async fn write_to<W: AsyncWrite + Unpin>(&self, writer: &mut W) -> io::Result<()> {
        writer.write_all(&self.header()).await?;
        writer.write_all(&self.payload).await
    }

    /// The next frame, or `None` at a clean end of stream (between frames).
    ///
    /// The kind byte is checked the moment it arrives, so a stream that is
    /// not frames fails at once instead of waiting out a length read from
    /// someone's login banner. An end of stream inside a header is
    /// undecodable too: those bytes were not a frame.
    pub async fn read_from<R: AsyncBufRead + Unpin>(
        reader: &mut R,
    ) -> Result<Option<Frame>, FrameError> {
        let mut header = [0; HEADER_BYTES];
        let mut filled = 0;
        while filled < HEADER_BYTES {
            let read = reader
                .read(&mut header[filled..])
                .await
                .map_err(FrameError::Io)?;
            if read == 0 {
                if filled == 0 {
                    return Ok(None);
                }
                return Err(undecodable(
                    "the stream ended inside a frame header",
                    &header[..filled],
                    reader,
                ));
            }
            filled += read;
            if Kind::from_byte(header[0]).is_none() {
                return Err(undecodable("unknown frame kind", &header[..filled], reader));
            }
        }
        let kind = Kind::from_byte(header[0]).expect("checked as it arrived");
        let id = u32::from_be_bytes([header[1], header[2], header[3], header[4]]);
        let length = u32::from_be_bytes([header[5], header[6], header[7], header[8]]);
        if length > MAX_PAYLOAD_BYTES {
            return Err(undecodable("frame length out of range", &header, reader));
        }
        let length = length as usize;
        let mut payload = Vec::with_capacity(length.min(64 * 1024));
        (&mut *reader)
            .take(length as u64)
            .read_to_end(&mut payload)
            .await
            .map_err(FrameError::Io)?;
        if payload.len() < length {
            return Err(FrameError::Io(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the stream ended inside a frame",
            )));
        }
        Ok(Some(Frame { kind, id, payload }))
    }
}

/// `consumed`, then whatever else is already buffered: the rest of the
/// chunk the bad bytes arrived in, which is what spells out what they are.
fn undecodable<R: AsyncBufRead + Unpin>(
    reason: &'static str,
    consumed: &[u8],
    reader: &mut R,
) -> FrameError {
    let buffered = buffered(reader);
    let mut received: Vec<u8> = consumed.iter().chain(buffered.iter()).copied().collect();
    let truncated = received.len() > QUOTED_BYTES;
    received.truncate(QUOTED_BYTES);
    FrameError::Undecodable {
        reason,
        received,
        truncated,
    }
}

/// What `reader` already holds, without waiting for more.
fn buffered<R: AsyncBufRead + Unpin>(reader: &mut R) -> Vec<u8> {
    let mut context = Context::from_waker(Waker::noop());
    match Pin::new(reader).poll_fill_buf(&mut context) {
        Poll::Ready(Ok(bytes)) => bytes.to_vec(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    //! The cases of `test/dsync_core/protocol/frame_codec_test.dart` that
    //! survive the redesign (no JSON, no scan-result kind).

    use std::time::Duration;

    use tokio::io::{AsyncWriteExt, BufReader, duplex};

    use super::*;

    const DEADLINE: Duration = Duration::from_secs(5);

    async fn read(reader: &mut (impl AsyncBufRead + Unpin)) -> Result<Option<Frame>, FrameError> {
        tokio::time::timeout(DEADLINE, Frame::read_from(reader))
            .await
            .expect("a frame read finished within its deadline")
    }

    fn quoted(error: FrameError) -> (Vec<u8>, bool) {
        match error {
            FrameError::Undecodable {
                received,
                truncated,
                ..
            } => (received, truncated),
            FrameError::Io(error) => panic!("an I/O error, not undecodable: {error}"),
        }
    }

    #[test]
    fn encodes_the_kind_then_a_big_endian_id_and_length() {
        let frame = Frame::new(Kind::Request, 0x0102_0304, vec![0xaa, 0xbb]);
        assert_eq!(
            frame.encode(),
            [
                0x02, 0x01, 0x02, 0x03, 0x04, 0x00, 0x00, 0x00, 0x02, 0xaa, 0xbb
            ]
        );
    }

    #[test]
    fn an_empty_payload_encodes_as_a_zero_length_frame() {
        assert_eq!(
            Frame::new(Kind::End, 7, Vec::new()).encode(),
            [0x05, 0, 0, 0, 7, 0, 0, 0, 0]
        );
    }

    #[tokio::test]
    async fn every_kind_round_trips_with_its_id_even_past_a_signed_int() {
        let frames: Vec<Frame> = Kind::ALL
            .into_iter()
            .enumerate()
            .map(|(n, kind)| Frame::new(kind, u32::MAX - n as u32, vec![n as u8; n]))
            .collect();
        let bytes: Vec<u8> = frames.iter().flat_map(Frame::encode).collect();
        // Several frames in one chunk.
        let mut reader = BufReader::new(bytes.as_slice());
        for frame in &frames {
            assert_eq!(read(&mut reader).await.unwrap().as_ref(), Some(frame));
        }
        assert!(read(&mut reader).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn decodes_frames_that_never_line_up_with_the_chunks_they_arrive_in() {
        let frames: Vec<Frame> = (0..50)
            .map(|n| Frame::new(Kind::Chunk, n, vec![n as u8; (n as usize * 37) % 300]))
            .collect();
        let bytes: Vec<u8> = frames.iter().flat_map(Frame::encode).collect();
        let (mut near, far) = duplex(64);
        let writer = tokio::spawn(async move {
            for piece in bytes.chunks(7) {
                near.write_all(piece).await.unwrap();
            }
        });
        let mut reader = BufReader::new(far);
        for frame in &frames {
            assert_eq!(read(&mut reader).await.unwrap().as_ref(), Some(frame));
        }
        writer.await.unwrap();
    }

    #[tokio::test]
    async fn decodes_a_multi_megabyte_frame() {
        let frame = Frame::new(Kind::Reply, 1, vec![3; 16 * 1024 * 1024]);
        let bytes = frame.encode();
        let mut reader = BufReader::new(bytes.as_slice());
        assert_eq!(read(&mut reader).await.unwrap(), Some(frame));
    }

    #[tokio::test]
    async fn fails_on_an_unknown_kind_at_once_and_quotes_what_came_with_it() {
        // The writer stays open: a decoder waiting out a length read from
        // the banner would hang here.
        let (mut near, far) = duplex(1024);
        near.write_all(b"Welcome to Ubuntu 24.04\n").await.unwrap();
        let mut reader = BufReader::new(far);
        let (received, truncated) = quoted(read(&mut reader).await.unwrap_err());
        assert_eq!(received, b"Welcome to Ubuntu 24.04\n");
        assert!(!truncated);
        drop(near);
    }

    #[tokio::test]
    async fn fails_on_a_length_out_of_range_rather_than_trusting_it() {
        let mut bytes = Frame::new(Kind::Chunk, 1, Vec::new()).encode();
        bytes[5..9].copy_from_slice(&(MAX_PAYLOAD_BYTES + 1).to_be_bytes());
        let (mut near, far) = duplex(1024);
        near.write_all(&bytes).await.unwrap();
        let mut reader = BufReader::new(far);
        let (received, _) = quoted(read(&mut reader).await.unwrap_err());
        assert_eq!(received, bytes);
        drop(near);
    }

    #[tokio::test]
    async fn keeps_only_a_glance_of_a_long_undecodable_stream() {
        let banner = vec![b'x'; 4096];
        let mut reader = BufReader::new(banner.as_slice());
        let (received, truncated) = quoted(read(&mut reader).await.unwrap_err());
        assert_eq!(received.len(), QUOTED_BYTES);
        assert!(truncated);
    }

    #[tokio::test]
    async fn a_stream_ending_inside_a_header_is_not_a_clean_end() {
        let bytes = &Frame::new(Kind::End, 1, Vec::new()).encode()[..4];
        let mut reader = BufReader::new(bytes);
        let (received, _) = quoted(read(&mut reader).await.unwrap_err());
        assert_eq!(received, bytes);
    }

    #[tokio::test]
    async fn a_stream_ending_inside_a_payload_fails_as_cut_short() {
        let bytes = Frame::new(Kind::Chunk, 1, vec![1; 10]).encode();
        let mut reader = BufReader::new(&bytes[..15]);
        match read(&mut reader).await {
            Err(FrameError::Io(error)) => assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof),
            other => panic!("not cut short: {other:?}"),
        }
    }
}
