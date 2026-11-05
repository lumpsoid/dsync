//! The peer:// preamble (SPEC §4.2): the frames a dialer and a listener
//! trade right after TLS, before the replica protocol's version frame.
//! The dialer claims the session it held before ([`Preamble::Claim`]); the
//! listener reads that claim first, sends [`Preamble::Draining`] while the
//! claimed session lands what it staged, and only then issues this
//! connection's token ([`Preamble::Issued`]).
//!
//! Every frame is the magic, the preamble's own `major.minor` as
//! big-endian `u32`s, a kind byte, a big-endian `u16` payload length and
//! the payload. A later minor may append to a payload. Read with exact
//! reads on the raw stream, never through a buffer: whatever follows the
//! preamble - the version frame - must still be on the stream for the
//! replica protocol's own reader.

use std::time::Duration;

use dsync_domain::FormatVersion;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::Instant;

use crate::link_error::LinkError;
use crate::session_token::SessionToken;

/// This build's preamble. The major moves on any change a peer would
/// decode wrong; the minor on one it can ignore.
pub(crate) const PREAMBLE_VERSION: FormatVersion = FormatVersion::new(1, 0);

/// Opens every preamble frame. A replica protocol version frame opens
/// with its kind and length instead, so a peer from before the preamble
/// reads as one.
const MAGIC: &[u8; 8] = b"dsync-ps";

/// The most the dialer waits for the listener's [`Preamble::Issued`]
/// without a [`Preamble::Draining`] frame lowering `queued_bytes` below
/// the lowest it has seen. Each frame restarts the handshake bound
/// (`Tuning::handshake`, in `dsync-domain`), so without this a paired
/// listener that drains forever would hold the dialer forever. An honest
/// drain lowers the figure with every chunk it hands a writer, so the
/// wait is held to progress, not to a total: an 8,000-file drain may
/// take minutes. A frame that repeats or raises the figure is a sign of
/// life, not progress; the first frame starts the clock.
pub(crate) const DRAINING_LIMIT: Duration = Duration::from_secs(60);

const CLAIM: u8 = 0x01;
const ISSUED: u8 = 0x02;
const DRAINING: u8 = 0x03;

#[derive(Debug)]
pub(crate) enum Preamble {
    /// Dialer to listener: the token of the session this dialer held on
    /// its last connection, if it holds one.
    Claim { reclaim: Option<SessionToken> },
    /// Listener to dialer: this connection's token.
    Issued { token: SessionToken },
    /// Listener to dialer, before [`Preamble::Issued`]: the claimed
    /// session is still landing what it staged, `queued_bytes` of it not
    /// yet handed to a writer. Sent every `Tuning::heartbeat`.
    Draining { queued_bytes: u64 },
}

impl Preamble {
    fn encode(&self) -> Vec<u8> {
        let (kind, payload) = match self {
            Preamble::Claim { reclaim: None } => (CLAIM, vec![0]),
            Preamble::Claim {
                reclaim: Some(token),
            } => {
                let mut payload = vec![1];
                payload.extend_from_slice(token.as_bytes());
                (CLAIM, payload)
            }
            Preamble::Issued { token } => (ISSUED, token.as_bytes().to_vec()),
            Preamble::Draining { queued_bytes } => (DRAINING, queued_bytes.to_be_bytes().to_vec()),
        };
        let mut frame = MAGIC.to_vec();
        frame.extend_from_slice(&PREAMBLE_VERSION.major().to_be_bytes());
        frame.extend_from_slice(&PREAMBLE_VERSION.minor().to_be_bytes());
        frame.push(kind);
        let length = u16::try_from(payload.len()).expect("a preamble payload is small");
        frame.extend_from_slice(&length.to_be_bytes());
        frame.extend_from_slice(&payload);
        frame
    }

    pub(crate) async fn write_to<W: AsyncWrite + Unpin>(
        &self,
        writer: &mut W,
    ) -> std::io::Result<()> {
        writer.write_all(&self.encode()).await?;
        writer.flush().await
    }

    /// Reads one frame with exact reads, taking nothing past its end.
    pub(crate) async fn read_from<R: AsyncRead + Unpin>(
        reader: &mut R,
    ) -> Result<Preamble, LinkError> {
        let mut magic = [0u8; 8];
        let got = read_up_to(reader, &mut magic).await?;
        if got == 0 {
            return Err(LinkError::ClosedBeforeHandshake);
        }
        if &magic[..got] != MAGIC.as_slice() {
            return Err(LinkError::NoPeerPreamble {
                received: magic[..got].to_vec(),
            });
        }
        let mut header = [0u8; 11];
        reader.read_exact(&mut header).await?;
        let word = |at: usize| u32::from_be_bytes(header[at..at + 4].try_into().unwrap());
        let remote = FormatVersion::new(word(0), word(4));
        if remote.major() != PREAMBLE_VERSION.major() {
            return Err(LinkError::PreambleVersionMismatch {
                local: PREAMBLE_VERSION,
                remote,
            });
        }
        let kind = header[8];
        let length = u16::from_be_bytes([header[9], header[10]]);
        let mut payload = vec![0u8; usize::from(length)];
        reader.read_exact(&mut payload).await?;
        decode(kind, &payload).ok_or_else(|| {
            LinkError::Protocol(format!(
                "an undecodable peer preamble frame (kind {kind:#04x}, {length} bytes)"
            ))
        })
    }
}

/// The frame of `kind` from `payload`; bytes past what this minor reads
/// are a later minor's and ignored.
fn decode(kind: u8, payload: &[u8]) -> Option<Preamble> {
    let token = |bytes: &[u8]| {
        let bytes: [u8; SessionToken::LEN] = bytes.get(..SessionToken::LEN)?.try_into().ok()?;
        Some(SessionToken::from_bytes(bytes))
    };
    match kind {
        CLAIM => match payload.first()? {
            0 => Some(Preamble::Claim { reclaim: None }),
            1 => Some(Preamble::Claim {
                reclaim: Some(token(&payload[1..])?),
            }),
            _ => None,
        },
        ISSUED => Some(Preamble::Issued {
            token: token(payload)?,
        }),
        DRAINING => Some(Preamble::Draining {
            queued_bytes: u64::from_be_bytes(payload.get(..8)?.try_into().ok()?),
        }),
        _ => None,
    }
}

/// Fills `buf` unless the stream ends first; how much it filled.
async fn read_up_to<R: AsyncRead + Unpin>(
    reader: &mut R,
    buf: &mut [u8],
) -> std::io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match reader.read(&mut buf[filled..]).await? {
            0 => break,
            read => filled += read,
        }
    }
    Ok(filled)
}

/// Why the dialer's half of the preamble failed.
#[derive(Debug)]
pub(crate) enum ClaimFailure {
    /// `deadline` passed: the listener went quiet.
    Late,
    Link(LinkError),
}

/// The lowest `queued_bytes` a draining listener has reported, and until
/// when the dialer waits for it to fall again.
#[derive(Clone, Copy)]
struct Progress {
    lowest: u64,
    limit: Instant,
}

/// The dialer's half: presents `reclaim` and answers the token the
/// listener issued. Bounded by `deadline`, which every
/// [`Preamble::Draining`] moves to `window` from its arrival, and a drain
/// by [`DRAINING_LIMIT`] from the last frame that lowered its
/// `queued_bytes`: past that the claim fails as
/// [`LinkError::StillDraining`]. `deadline` itself is left uncapped, so
/// what follows the preamble still has its window after an honest drain.
pub(crate) async fn claim<S>(
    stream: &mut S,
    reclaim: Option<SessionToken>,
    deadline: &mut Instant,
    window: Duration,
) -> Result<SessionToken, ClaimFailure>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    // A listener that refuses this host closes before this write lands;
    // that it closed is read first, because that is what says why.
    let sent = tokio::time::timeout_at(*deadline, Preamble::Claim { reclaim }.write_to(stream))
        .await
        .map_err(|_| ClaimFailure::Late)?;
    let mut draining: Option<Progress> = None;
    loop {
        let wait = draining.map_or(*deadline, |progress| (*deadline).min(progress.limit));
        let frame = tokio::time::timeout_at(wait, Preamble::read_from(stream))
            .await
            .map_err(|_| match draining {
                Some(progress) if wait == progress.limit => {
                    ClaimFailure::Link(LinkError::StillDraining {
                        limit: DRAINING_LIMIT,
                        queued_bytes: progress.lowest,
                    })
                }
                _ => ClaimFailure::Late,
            })?
            .map_err(ClaimFailure::Link)?;
        match frame {
            Preamble::Issued { token } => {
                sent.map_err(|error| ClaimFailure::Link(error.into()))?;
                return Ok(token);
            }
            Preamble::Draining { queued_bytes } => {
                let now = Instant::now();
                if draining.is_none_or(|progress| queued_bytes < progress.lowest) {
                    draining = Some(Progress {
                        lowest: queued_bytes,
                        limit: now + DRAINING_LIMIT,
                    });
                }
                *deadline = now + window;
            }
            Preamble::Claim { .. } => {
                return Err(ClaimFailure::Link(LinkError::Protocol(
                    "a claim from the listener".into(),
                )));
            }
        }
    }
}

/// The listener's first step: what the dialer claimed. Unbounded: the
/// caller holds it to its deadline.
pub(crate) async fn read_claim<S>(stream: &mut S) -> Result<Option<SessionToken>, LinkError>
where
    S: AsyncRead + Unpin,
{
    match Preamble::read_from(stream).await? {
        Preamble::Claim { reclaim } => Ok(reclaim),
        other => Err(LinkError::Protocol(format!(
            "a {other:?} preamble frame from the dialer"
        ))),
    }
}

/// Tells the dialer the session it claimed still has `queued_bytes` to
/// hand its writers. A failed write is a dialer that has gone.
pub(crate) async fn write_draining<S>(stream: &mut S, queued_bytes: u64) -> std::io::Result<()>
where
    S: AsyncWrite + Unpin,
{
    Preamble::Draining { queued_bytes }.write_to(stream).await
}

/// The listener's last step: issues `token`, after which nothing but the
/// version frame follows. Unbounded: the caller holds it to its deadline.
pub(crate) async fn write_issued<S>(stream: &mut S, token: &SessionToken) -> std::io::Result<()>
where
    S: AsyncWrite + Unpin,
{
    Preamble::Issued {
        token: token.clone(),
    }
    .write_to(stream)
    .await
}

#[cfg(test)]
mod tests {
    use tokio::io::{BufReader, duplex};

    use super::*;
    use crate::version_handshake::{PROTOCOL_VERSION, handshake, version_frame};

    const DEADLINE: Duration = Duration::from_secs(5);

    async fn round_trip(frame: Preamble) -> Preamble {
        let (mut near, mut far) = duplex(1024);
        frame.write_to(&mut near).await.unwrap();
        Preamble::read_from(&mut far).await.unwrap()
    }

    #[tokio::test]
    async fn every_frame_round_trips() {
        let token = SessionToken::generate();
        match round_trip(Preamble::Claim { reclaim: None }).await {
            Preamble::Claim { reclaim: None } => {}
            other => panic!("{other:?}"),
        }
        match round_trip(Preamble::Claim {
            reclaim: Some(token.clone()),
        })
        .await
        {
            Preamble::Claim {
                reclaim: Some(read),
            } => assert!(read.is(&token)),
            other => panic!("{other:?}"),
        }
        match round_trip(Preamble::Issued {
            token: token.clone(),
        })
        .await
        {
            Preamble::Issued { token: read } => assert!(read.is(&token)),
            other => panic!("{other:?}"),
        }
        match round_trip(Preamble::Draining {
            queued_bytes: 1 << 40,
        })
        .await
        {
            Preamble::Draining { queued_bytes } => assert_eq!(queued_bytes, 1 << 40),
            other => panic!("{other:?}"),
        }
    }

    #[tokio::test]
    async fn a_version_frame_in_its_place_is_refused_as_no_preamble() {
        let (mut near, mut far) = duplex(1024);
        version_frame(PROTOCOL_VERSION)
            .write_to(&mut near)
            .await
            .unwrap();
        let error = Preamble::read_from(&mut far).await.unwrap_err();
        assert!(
            matches!(&error, LinkError::NoPeerPreamble { received } if received.len() == 8),
            "{error:?}"
        );
        assert!(error.to_string().contains("peer:// preamble"), "{error}");
    }

    #[tokio::test]
    async fn another_preamble_major_is_refused_naming_both() {
        let mut frame = Preamble::Claim { reclaim: None }.encode();
        frame[8..12].copy_from_slice(&2u32.to_be_bytes());
        let (mut near, mut far) = duplex(1024);
        near.write_all(&frame).await.unwrap();
        let error = Preamble::read_from(&mut far).await.unwrap_err();
        assert!(
            matches!(
                error,
                LinkError::PreambleVersionMismatch { local, remote }
                    if local == PREAMBLE_VERSION && remote == FormatVersion::new(2, 0)
            ),
            "{error:?}"
        );
        // Positive control: a later minor that appends is read.
        let mut frame = Preamble::Draining { queued_bytes: 7 }.encode();
        frame[12..16].copy_from_slice(&9u32.to_be_bytes());
        frame[18] += 3;
        frame.extend_from_slice(b"new");
        let (mut near, mut far) = duplex(1024);
        near.write_all(&frame).await.unwrap();
        assert!(matches!(
            Preamble::read_from(&mut far).await.unwrap(),
            Preamble::Draining { queued_bytes: 7 }
        ));
    }

    #[tokio::test]
    async fn a_stream_that_ends_first_is_closed_before_the_handshake() {
        let (near, mut far) = duplex(1024);
        drop(near);
        assert!(matches!(
            Preamble::read_from(&mut far).await,
            Err(LinkError::ClosedBeforeHandshake)
        ));
    }

    /// Both halves over one stream, then the replica protocol's handshake
    /// on what is left of it: the preamble read took nothing past itself.
    #[tokio::test]
    async fn the_version_frame_after_the_preamble_is_intact() {
        let (mut dialer, mut listener) = duplex(1024);
        let issued = SessionToken::generate();
        let held = SessionToken::generate();
        let (claimed, answered) = tokio::time::timeout(DEADLINE, async {
            tokio::join!(
                async {
                    let mut deadline = Instant::now() + DEADLINE;
                    let token = claim(&mut dialer, Some(held.clone()), &mut deadline, DEADLINE)
                        .await
                        .unwrap();
                    version_frame(PROTOCOL_VERSION)
                        .write_to(&mut dialer)
                        .await
                        .unwrap();
                    token
                },
                async {
                    let reclaim = read_claim(&mut listener).await.unwrap();
                    write_draining(&mut listener, 3).await.unwrap();
                    write_issued(&mut listener, &issued).await.unwrap();
                    let (read, mut write) = tokio::io::split(&mut listener);
                    let agreed = handshake(&mut BufReader::new(read), &mut write).await;
                    (reclaim, agreed)
                }
            )
        })
        .await
        .unwrap();
        assert!(claimed.is(&issued));
        let (reclaim, agreed) = answered;
        assert!(reclaim.unwrap().is(&held));
        assert_eq!(agreed.unwrap(), PROTOCOL_VERSION);
    }

    /// A listener that sends a `Draining` frame for each of `draining`,
    /// then its token, each `gap` after the last; the claim's window is
    /// `window`.
    async fn claim_against(
        draining: Vec<u64>,
        gap: Duration,
        window: Duration,
    ) -> Result<(), ClaimFailure> {
        claim_timed(draining, gap, window).await.0
    }

    /// [`claim_against`], and how long the claim took. The listener stops
    /// at the first write the dialer is no longer there to read.
    async fn claim_timed(
        draining: Vec<u64>,
        gap: Duration,
        window: Duration,
    ) -> (Result<(), ClaimFailure>, Duration) {
        let (mut dialer, mut listener) = duplex(1024);
        let far = tokio::spawn(async move {
            Preamble::read_from(&mut listener).await.unwrap();
            for queued_bytes in draining {
                tokio::time::sleep(gap).await;
                if write_draining(&mut listener, queued_bytes).await.is_err() {
                    return;
                }
            }
            tokio::time::sleep(gap).await;
            let _ = write_issued(&mut listener, &SessionToken::generate()).await;
        });
        let started = Instant::now();
        let mut deadline = started + window;
        let claimed = claim(&mut dialer, None, &mut deadline, window).await;
        let took = started.elapsed();
        drop(dialer);
        far.await.unwrap();
        (claimed.map(|_| ()), took)
    }

    fn still_draining(claimed: Result<(), ClaimFailure>) -> LinkError {
        match claimed {
            Err(ClaimFailure::Link(error @ LinkError::StillDraining { .. })) => error,
            other => panic!("{other:?}"),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_drain_that_stops_lowering_its_bytes_fails_naming_the_limit() {
        let window = Duration::from_secs(10);
        let gap = Duration::from_secs(8);
        // Lowered to 80 at 24 s, then a frame every 8 s, each inside the
        // window, that never lowers it again.
        let mut stalled = vec![100, 90, 80];
        stalled.extend([80, 85, 80].repeat(7));
        let (claimed, took) = claim_timed(stalled, gap, window).await;
        let error = still_draining(claimed);
        assert_eq!(took, 3 * gap + DRAINING_LIMIT);
        assert!(
            matches!(error, LinkError::StillDraining { queued_bytes: 80, limit } if limit == DRAINING_LIMIT),
            "{error:?}"
        );
        assert!(error.to_string().contains("still landing"), "{error}");
        // A figure that only rises was never progress past the first.
        let rising = (1..=20).map(|step| step * 10).collect();
        let (claimed, took) = claim_timed(rising, gap, window).await;
        still_draining(claimed);
        assert_eq!(took, gap + DRAINING_LIMIT);
        // Positive control: a drain far longer than the limit that keeps
        // lowering the figure connects.
        let falling = (0..20).rev().map(|step| step * 10).collect();
        let (claimed, took) = claim_timed(falling, gap, window).await;
        assert!(claimed.is_ok(), "{claimed:?}");
        assert_eq!(took, 21 * gap);
        assert!(took > 2 * DRAINING_LIMIT);
    }

    /// One large landing: frames every heartbeat, most repeating the
    /// figure, which falls one chunk now and then. Waited on as long as
    /// each fall comes inside the limit.
    #[tokio::test(start_paused = true)]
    async fn one_large_landing_falling_chunk_by_chunk_is_waited_on() {
        let window = Duration::from_secs(10);
        let heartbeat = Duration::from_secs(5);
        const CHUNK: u64 = 4 << 20;
        const SIZE: u64 = 4 << 30;
        // A chunk handed to the writer every `every` frames, 40 frames.
        let landing = |every: u64| (0..40).map(|frame| SIZE - frame / every * CHUNK).collect();
        // Every 50 s: 205 s in all.
        let (claimed, took) = claim_timed(landing(10), heartbeat, window).await;
        assert!(claimed.is_ok(), "{claimed:?}");
        assert_eq!(took, 41 * heartbeat);
        // Every 65 s: the first frame's figure stands past the limit.
        let (claimed, took) = claim_timed(landing(13), heartbeat, window).await;
        still_draining(claimed);
        assert_eq!(took, heartbeat + DRAINING_LIMIT);
    }

    /// The tail of a drain: nothing left to hand a writer, the last
    /// landings still being written, so frames repeat 0. Reaching 0 is
    /// the last progress; the tail gets `DRAINING_LIMIT` from there.
    #[tokio::test(start_paused = true)]
    async fn a_tail_with_nothing_queued_gets_the_limit_from_when_it_reached_zero() {
        let window = Duration::from_secs(10);
        let heartbeat = Duration::from_secs(5);
        let tail = |frames: usize| {
            let mut drain = vec![4096, 0];
            drain.extend(std::iter::repeat_n(0, frames));
            drain
        };
        // 0 at 10 s, then ten more frames: answered at 65 s.
        let (claimed, took) = claim_timed(tail(10), heartbeat, window).await;
        assert!(claimed.is_ok(), "{claimed:?}");
        assert_eq!(took, 13 * heartbeat);
        // A tail that outlasts the limit fails it, 60 s after the 0.
        let (claimed, took) = claim_timed(tail(20), heartbeat, window).await;
        let error = still_draining(claimed);
        assert!(
            matches!(
                error,
                LinkError::StillDraining {
                    queued_bytes: 0,
                    ..
                }
            ),
            "{error:?}"
        );
        assert_eq!(took, 2 * heartbeat + DRAINING_LIMIT);
    }

    #[tokio::test(start_paused = true)]
    async fn each_draining_frame_moves_the_deadline() {
        let window = Duration::from_secs(10);
        let gap = Duration::from_secs(8);
        // Answered 24 s in, past two windows: each draining frame moved it.
        assert!(claim_against(vec![1, 0], gap, window).await.is_ok());
        // Positive control: the same wait with no draining is late.
        assert!(matches!(
            claim_against(Vec::new(), 2 * gap, window).await,
            Err(ClaimFailure::Late)
        ));
    }
}
