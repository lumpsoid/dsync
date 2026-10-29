//! The first exchange on a replica connection (SPEC §4.2, §8.4): each
//! side sends its protocol version, `major.minor`, then reads the other's.
//! A different major ends the connection; the same major goes ahead at the
//! lower of the two minors.

use dsync_domain::FormatVersion;
use tokio::io::{AsyncBufRead, AsyncWrite, AsyncWriteExt};

use crate::frame::{Frame, FrameError, Kind, NO_REQUEST, QUOTED_BYTES};
use crate::link_error::LinkError;

/// This build's protocol. The major moves on any change a peer would
/// otherwise decode silently wrong - a message field renamed or
/// repurposed, an operation replaced; the minor on one an older peer can
/// ignore or never be asked for.
///
/// 2.0 drops the write-in-place marks (the `Intent` and `Withdraw`
/// commits, the untrusted statuses and their tally, the `open` write
/// stage). Every 2.x session has the `Cancel` frame 1.1 added.
pub const PROTOCOL_VERSION: FormatVersion = FormatVersion::new(2, 0);

/// Opens every version frame, so a stream that happens to start with the
/// version kind byte is still not mistaken for the protocol.
const MAGIC: &[u8; 8] = b"dsync-rp";

/// Sends this side's version and checks the far side's, answering the
/// version the session speaks: the lower minor of the shared major.
///
/// Undecodable first bytes are not a protocol bug but a far side that is
/// not speaking the protocol yet - in practice a remote shell printing a
/// banner over it - so they come back quoted in
/// [`LinkError::NotSpeakingProtocol`].
pub(crate) async fn handshake<R, W>(
    reader: &mut R,
    writer: &mut W,
) -> Result<FormatVersion, LinkError>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    handshake_as(PROTOCOL_VERSION, reader, writer).await
}

pub(crate) async fn handshake_as<R, W>(
    version: FormatVersion,
    reader: &mut R,
    writer: &mut W,
) -> Result<FormatVersion, LinkError>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    // A far side that exits at once (ssh's `command not found`) may close
    // its end before this write lands; what it sent, or that it closed, is
    // read first, because that is what says why.
    let sent = send_version(version, writer).await;
    let frame = match Frame::read_from(reader).await {
        Ok(Some(frame)) => frame,
        Ok(None) => return Err(LinkError::ClosedBeforeHandshake),
        Err(FrameError::Io(error)) => return Err(error.into()),
        Err(FrameError::Undecodable {
            received,
            truncated,
            ..
        }) => {
            return Err(LinkError::NotSpeakingProtocol {
                received,
                truncated,
            });
        }
    };
    let remote = version_of(&frame).ok_or_else(|| {
        let mut received = frame.encode();
        let truncated = received.len() > QUOTED_BYTES;
        received.truncate(QUOTED_BYTES);
        LinkError::NotSpeakingProtocol {
            received,
            truncated,
        }
    })?;
    let agreed = version
        .agree(remote)
        .map_err(|mismatch| LinkError::VersionMismatch {
            local: mismatch.ours(),
            remote: mismatch.theirs(),
        })?;
    sent?;
    Ok(agreed)
}

async fn send_version<W: AsyncWrite + Unpin>(
    version: FormatVersion,
    writer: &mut W,
) -> std::io::Result<()> {
    version_frame(version).write_to(writer).await?;
    writer.flush().await
}

/// The magic, then the major and the minor as big-endian `u32`s. This
/// layout is the one thing no major may change, since it is how two
/// majors tell each other apart; a later minor may append to it.
pub(crate) fn version_frame(version: FormatVersion) -> Frame {
    let mut payload = MAGIC.to_vec();
    payload.extend_from_slice(&version.major().to_be_bytes());
    payload.extend_from_slice(&version.minor().to_be_bytes());
    Frame::new(Kind::Version, NO_REQUEST, payload)
}

fn version_of(frame: &Frame) -> Option<FormatVersion> {
    if frame.kind != Kind::Version || frame.id != NO_REQUEST {
        return None;
    }
    let version = frame.payload.strip_prefix(MAGIC.as_slice())?;
    let word = |at: usize| {
        Some(u32::from_be_bytes(
            version.get(at..at + 4)?.try_into().ok()?,
        ))
    };
    Some(FormatVersion::new(word(0)?, word(4)?))
}

#[cfg(test)]
mod tests {
    //! The cases of `test/dsync_core/protocol/version_handshake_test.dart`.

    use std::time::Duration;

    use tokio::io::{AsyncWriteExt, BufReader, duplex};

    use super::*;

    const DEADLINE: Duration = Duration::from_secs(5);

    /// Both ends of a connection shaking hands as `near` and `far`.
    async fn shake(
        near: FormatVersion,
        far: FormatVersion,
    ) -> (
        Result<FormatVersion, LinkError>,
        Result<FormatVersion, LinkError>,
    ) {
        let (a, b) = duplex(1024);
        let (a_read, mut a_write) = tokio::io::split(a);
        let (b_read, mut b_write) = tokio::io::split(b);
        let mut a_read = BufReader::new(a_read);
        let mut b_read = BufReader::new(b_read);
        tokio::time::timeout(DEADLINE, async {
            tokio::join!(
                handshake_as(near, &mut a_read, &mut a_write),
                handshake_as(far, &mut b_read, &mut b_write)
            )
        })
        .await
        .expect("the handshake finished within its deadline")
    }

    /// This side's handshake against a far side that only writes `bytes`.
    async fn against(bytes: &[u8], then_close: bool) -> LinkError {
        let (near, mut far) = duplex(64 * 1024);
        far.write_all(bytes).await.unwrap();
        let far = (!then_close).then_some(far);
        let (read, mut write) = tokio::io::split(near);
        let mut read = BufReader::new(read);
        let error = tokio::time::timeout(DEADLINE, handshake(&mut read, &mut write))
            .await
            .expect("the handshake finished within its deadline")
            .unwrap_err();
        drop(far);
        error
    }

    const V1_0: FormatVersion = FormatVersion::new(1, 0);
    const V1_3: FormatVersion = FormatVersion::new(1, 3);
    const V2_0: FormatVersion = FormatVersion::new(2, 0);
    const V2_3: FormatVersion = FormatVersion::new(2, 3);

    #[tokio::test]
    async fn succeeds_when_both_ends_speak_the_same_version() {
        let (near, far) = shake(PROTOCOL_VERSION, PROTOCOL_VERSION).await;
        assert_eq!(near.unwrap(), PROTOCOL_VERSION);
        assert_eq!(far.unwrap(), PROTOCOL_VERSION);
        assert_eq!(PROTOCOL_VERSION, V2_0);
    }

    #[tokio::test]
    async fn the_same_major_at_different_minors_speaks_the_lower_one() {
        let (near, far) = shake(V1_0, V1_3).await;
        assert_eq!(near.unwrap(), V1_0);
        assert_eq!(far.unwrap(), V1_0);
    }

    #[tokio::test]
    async fn a_later_minor_may_append_to_the_version_frame() {
        let mut frame = version_frame(V2_3);
        frame.payload.extend_from_slice(b"more");
        let (near, mut far) = duplex(1024);
        frame.write_to(&mut far).await.unwrap();
        let (read, mut write) = tokio::io::split(near);
        let agreed =
            tokio::time::timeout(DEADLINE, handshake(&mut BufReader::new(read), &mut write))
                .await
                .unwrap();
        assert_eq!(agreed.unwrap(), V2_0);
    }

    #[tokio::test]
    async fn fails_both_ends_when_the_majors_differ_naming_both() {
        let (near, far) = shake(V1_3, V2_0).await;
        assert!(matches!(
            near,
            Err(LinkError::VersionMismatch {
                local: V1_3,
                remote: V2_0
            })
        ));
        let far = far.unwrap_err();
        assert!(
            matches!(
                far,
                LinkError::VersionMismatch {
                    local: V2_0,
                    remote: V1_3
                }
            ),
            "{far:?}"
        );
        let text = far.to_string();
        assert!(
            text.contains("this side speaks 2.0, the far side 1.3"),
            "{text}"
        );
    }

    #[tokio::test]
    async fn quotes_what_the_peer_sent_when_its_first_bytes_are_not_frames() {
        let error = against(
            b"Welcome to Ubuntu 24.04 LTS\n\n * Documentation: https://help.ubuntu.com\n",
            false,
        )
        .await;
        let LinkError::NotSpeakingProtocol { received, .. } = &error else {
            panic!("not a banner: {error:?}");
        };
        assert!(received.starts_with(b"Welcome to Ubuntu"));
        let text = error.to_string();
        assert!(text.contains("  Welcome to Ubuntu 24.04 LTS"), "{text}");
        assert!(text.contains("  * Documentation"), "{text}");
    }

    #[tokio::test]
    async fn a_frame_that_is_not_a_version_frame_is_not_the_protocol_either() {
        let request = Frame::new(Kind::Request, 1, b"hi".to_vec()).encode();
        assert!(matches!(
            against(&request, false).await,
            LinkError::NotSpeakingProtocol { received, .. } if received == request
        ));
    }

    #[tokio::test]
    async fn a_banner_from_a_far_side_that_then_exits_is_still_quoted() {
        assert!(matches!(
            against(b"motd: hello\n", true).await,
            LinkError::NotSpeakingProtocol { received, .. } if received == b"motd: hello\n"
        ));
    }

    #[tokio::test]
    async fn a_far_side_that_closes_first_is_not_a_banner() {
        assert!(matches!(
            against(b"", true).await,
            LinkError::ClosedBeforeHandshake
        ));
    }
}
