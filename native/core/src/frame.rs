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

use crate::credit::STREAM_CREDIT_BYTES;

pub(crate) const HEADER_BYTES: usize = 9;

// The largest payload each kind may announce ([`Kind::max_payload_bytes`]),
// checked from the header before a byte of the payload is read, so a
// corrupt or hostile length is refused rather than held: a peer can make
// this end keep at most one frame of its kind's cap per connection. The
// payload is never allocated up front at the announced size either.

/// The magic and two `u32`s, with room for whatever a later minor appends
/// (SPEC §4.2).
pub(crate) const MAX_VERSION_BYTES: u32 = 1024;

/// A request or reply carries no listing - a scan phase's follows it as
/// a body ([`crate::listing`]) - so its largest is a commit batch, which
/// the initiator splits to fit ([`crate::remote_replica`]), or a path or
/// two and an error's message.
pub(crate) const MAX_REQUEST_BYTES: u32 = 256 * 1024;

pub(crate) const MAX_REPLY_BYTES: u32 = 256 * 1024;

/// No chunk is past its body's credit, so none is past the whole credit.
pub(crate) const MAX_CHUNK_BYTES: u32 = STREAM_CREDIT_BYTES as u32;

/// A read's `End` carries what the file was once read; a write's is empty.
pub(crate) const MAX_END_BYTES: u32 = 4 * 1024;

/// A postcard [`crate::wire::WireIo`]: an error kind and its message.
pub(crate) const MAX_FAIL_BYTES: u32 = 64 * 1024;

/// A big-endian `u32` of bytes.
pub(crate) const MAX_CREDIT_BYTES: u32 = 4;

/// `Heartbeat` and `Cancel` are empty.
pub(crate) const MAX_EMPTY_BYTES: u32 = 0;

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
    /// Room the receiver of a body has made for more of it: a big-endian
    /// u32 of bytes (SPEC §4.2, [`crate::credit`]).
    Credit,
    /// The receiver of a read body asking its sender to stop: empty. The
    /// sender ends the body with a `Fail` (SPEC §4.2).
    Cancel,
}

impl Kind {
    const ALL: [Kind; 9] = [
        Kind::Version,
        Kind::Request,
        Kind::Reply,
        Kind::Chunk,
        Kind::End,
        Kind::Fail,
        Kind::Heartbeat,
        Kind::Credit,
        Kind::Cancel,
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
            Kind::Credit => 0x08,
            Kind::Cancel => 0x09,
        }
    }

    fn from_byte(byte: u8) -> Option<Kind> {
        Kind::ALL.into_iter().find(|kind| kind.byte() == byte)
    }

    /// The largest payload a frame of this kind may announce.
    pub(crate) fn max_payload_bytes(self) -> u32 {
        match self {
            Kind::Version => MAX_VERSION_BYTES,
            Kind::Request => MAX_REQUEST_BYTES,
            Kind::Reply => MAX_REPLY_BYTES,
            Kind::Chunk => MAX_CHUNK_BYTES,
            Kind::End => MAX_END_BYTES,
            Kind::Fail => MAX_FAIL_BYTES,
            Kind::Credit => MAX_CREDIT_BYTES,
            Kind::Heartbeat | Kind::Cancel => MAX_EMPTY_BYTES,
        }
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

    /// The header announcing this frame; an error, not a frame, for a
    /// payload past its kind's [`Kind::max_payload_bytes`], which no reader
    /// would accept (and past `u32::MAX`, no header could even announce).
    pub fn header(&self) -> io::Result<[u8; HEADER_BYTES]> {
        let most = self.kind.max_payload_bytes();
        let length = u32::try_from(self.payload.len())
            .ok()
            .filter(|length| *length <= most)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!(
                        "a {:?} frame payload of {} bytes, past the {most} that kind may carry",
                        self.kind,
                        self.payload.len()
                    ),
                )
            })?;
        let mut header = [0; HEADER_BYTES];
        header[0] = self.kind.byte();
        header[1..5].copy_from_slice(&self.id.to_be_bytes());
        header[5..9].copy_from_slice(&length.to_be_bytes());
        Ok(header)
    }

    /// Header and payload, as written.
    pub fn encode(&self) -> io::Result<Vec<u8>> {
        let mut bytes = Vec::with_capacity(HEADER_BYTES + self.payload.len());
        bytes.extend_from_slice(&self.header()?);
        bytes.extend_from_slice(&self.payload);
        Ok(bytes)
    }

    /// Writes this frame; the caller flushes. An oversized payload fails
    /// before a byte is written, so the stream stays in step.
    pub async fn write_to<W: AsyncWrite + Unpin>(&self, writer: &mut W) -> io::Result<()> {
        writer.write_all(&self.header()?).await?;
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
        if length > kind.max_payload_bytes() {
            return Err(undecodable(
                "frame length out of range for its kind",
                &header,
                reader,
            ));
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
            frame.encode().unwrap(),
            [
                0x02, 0x01, 0x02, 0x03, 0x04, 0x00, 0x00, 0x00, 0x02, 0xaa, 0xbb
            ]
        );
    }

    #[test]
    fn an_empty_payload_encodes_as_a_zero_length_frame() {
        assert_eq!(
            Frame::new(Kind::End, 7, Vec::new()).encode().unwrap(),
            [0x05, 0, 0, 0, 7, 0, 0, 0, 0]
        );
    }

    #[tokio::test]
    async fn a_payload_past_its_kind_s_cap_is_an_error_and_writes_nothing() {
        for kind in Kind::ALL {
            let cap = kind.max_payload_bytes() as usize;
            // `vec![0; n]` is a zeroed allocation: its pages are never touched.
            let largest = Frame::new(kind, 1, vec![0; cap]);
            assert!(largest.header().is_ok(), "{kind:?}");
            let oversized = Frame::new(kind, 1, vec![0; cap + 1]);
            let error = oversized.header().unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput, "{kind:?}");
            let mut written = Vec::new();
            let error = oversized.write_to(&mut written).await.unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput, "{kind:?}");
            assert!(written.is_empty(), "{kind:?}");
        }
    }

    #[test]
    fn the_caps_bound_what_each_kind_genuinely_carries() {
        assert_eq!(Kind::Heartbeat.max_payload_bytes(), 0);
        assert_eq!(Kind::Cancel.max_payload_bytes(), 0);
        assert_eq!(Kind::Credit.max_payload_bytes(), 4);
        assert_eq!(
            Kind::Chunk.max_payload_bytes() as usize,
            STREAM_CREDIT_BYTES
        );
        // Every frame this protocol sends of the small kinds fits.
        assert!(
            crate::credit::grant_frame(1, STREAM_CREDIT_BYTES)
                .header()
                .is_ok()
        );
        assert!(
            crate::version_handshake::version_frame(crate::version_handshake::PROTOCOL_VERSION)
                .header()
                .is_ok()
        );
        let read_end = crate::wire::encode(&dsync_domain::OnDisk::File {
            size: u64::MAX,
            mtime_us: i64::MIN,
        });
        assert!(Frame::new(Kind::End, 1, read_end).header().is_ok());
        let failure = io::Error::other("x".repeat(4096));
        let failure = crate::wire::WireIo::encode_failure(&failure);
        assert!(Frame::new(Kind::Fail, 1, failure).header().is_ok());
    }

    /// A header announcing `length` for `kind`, fed alone over a stream
    /// that stays open: what reading it comes to within `wait`, `None`
    /// when it is still waiting on the payload.
    async fn read_header_only(
        kind: Kind,
        length: u32,
        wait: Duration,
    ) -> Option<Result<Option<Frame>, FrameError>> {
        let mut header = Frame::new(kind, 1, Vec::new()).header().unwrap();
        header[5..9].copy_from_slice(&length.to_be_bytes());
        let (mut near, far) = duplex(1024);
        near.write_all(&header).await.unwrap();
        let mut reader = BufReader::new(far);
        let read = tokio::time::timeout(wait, Frame::read_from(&mut reader))
            .await
            .ok();
        drop(near);
        read
    }

    #[tokio::test]
    async fn a_length_past_its_kind_s_cap_is_refused_from_the_header_alone() {
        for kind in Kind::ALL {
            let past = kind.max_payload_bytes() + 1;
            let read = read_header_only(kind, past, DEADLINE)
                .await
                .unwrap_or_else(|| panic!("{kind:?} waited on a payload past its cap"));
            let (received, _) = quoted(read.unwrap_err());
            assert_eq!(received[0], kind.byte(), "{kind:?}");
            assert_eq!(&received[5..9], past.to_be_bytes(), "{kind:?}");
        }
    }

    #[tokio::test]
    async fn a_length_at_its_kind_s_cap_waits_for_the_payload() {
        // The control for the refusal above: at the cap the same header is
        // taken, and the read waits on bytes that never come.
        for kind in Kind::ALL {
            let at = kind.max_payload_bytes();
            let read = read_header_only(kind, at, Duration::from_millis(50)).await;
            if at == 0 {
                assert!(matches!(read, Some(Ok(Some(_)))), "{kind:?}: {read:?}");
            } else {
                assert!(read.is_none(), "{kind:?}: {read:?}");
            }
        }
    }

    #[tokio::test]
    async fn every_kind_round_trips_with_its_id_even_past_a_signed_int() {
        let frames: Vec<Frame> = Kind::ALL
            .into_iter()
            .enumerate()
            .map(|(n, kind)| {
                let length = n.min(kind.max_payload_bytes() as usize);
                Frame::new(kind, u32::MAX - n as u32, vec![n as u8; length])
            })
            .collect();
        let bytes: Vec<u8> = frames.iter().flat_map(|f| f.encode().unwrap()).collect();
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
        let bytes: Vec<u8> = frames.iter().flat_map(|f| f.encode().unwrap()).collect();
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
    async fn decodes_a_frame_at_its_kind_s_cap() {
        let frame = Frame::new(Kind::Reply, 1, vec![3; MAX_REPLY_BYTES as usize]);
        let bytes = frame.encode().unwrap();
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
        let mut bytes = Frame::new(Kind::Chunk, 1, Vec::new()).encode().unwrap();
        bytes[5..9].copy_from_slice(&(MAX_CHUNK_BYTES + 1).to_be_bytes());
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
        let bytes = &Frame::new(Kind::End, 1, Vec::new()).encode().unwrap()[..4];
        let mut reader = BufReader::new(bytes);
        let (received, _) = quoted(read(&mut reader).await.unwrap_err());
        assert_eq!(received, bytes);
    }

    #[tokio::test]
    async fn a_stream_ending_inside_a_payload_fails_as_cut_short() {
        let bytes = Frame::new(Kind::Chunk, 1, vec![1; 10]).encode().unwrap();
        let mut reader = BufReader::new(&bytes[..15]);
        match read(&mut reader).await {
            Err(FrameError::Io(error)) => assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof),
            other => panic!("not cut short: {other:?}"),
        }
    }
}
