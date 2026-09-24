//! The first exchange on a replica connection (SPEC §4.2, plan D5): each
//! side sends its protocol version, then reads the other's, and anything
//! but exact equality ends the connection.

use tokio::io::{AsyncBufRead, AsyncWrite, AsyncWriteExt};

use crate::frame::{Frame, FrameError, Kind, NO_REQUEST, QUOTED_BYTES};
use crate::link_error::LinkError;

/// This build's protocol. Bumped on any change a peer would otherwise
/// decode silently wrong: a message field renamed or repurposed, an
/// operation replaced. Started at 1 for the Rust protocol, which shares
/// nothing with the Dart one.
pub const PROTOCOL_VERSION: u32 = 1;

/// Opens every version frame, so a stream that happens to start with the
/// version kind byte is still not mistaken for the protocol.
const MAGIC: &[u8; 8] = b"dsync-rp";

/// Sends this side's version and checks the far side's.
///
/// Undecodable first bytes are not a protocol bug but a far side that is
/// not speaking the protocol yet - in practice a remote shell printing a
/// banner over it - so they come back quoted in
/// [`LinkError::NotSpeakingProtocol`].
pub(crate) async fn handshake<R, W>(reader: &mut R, writer: &mut W) -> Result<(), LinkError>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    handshake_as(PROTOCOL_VERSION, reader, writer).await
}

pub(crate) async fn handshake_as<R, W>(
    version: u32,
    reader: &mut R,
    writer: &mut W,
) -> Result<(), LinkError>
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
    if remote != version {
        return Err(LinkError::VersionMismatch {
            local: version,
            remote,
        });
    }
    Ok(sent?)
}

async fn send_version<W: AsyncWrite + Unpin>(version: u32, writer: &mut W) -> std::io::Result<()> {
    version_frame(version).write_to(writer).await?;
    writer.flush().await
}

pub(crate) fn version_frame(version: u32) -> Frame {
    let mut payload = MAGIC.to_vec();
    payload.extend_from_slice(&version.to_be_bytes());
    Frame::new(Kind::Version, NO_REQUEST, payload)
}

fn version_of(frame: &Frame) -> Option<u32> {
    if frame.kind != Kind::Version || frame.id != NO_REQUEST {
        return None;
    }
    let version = frame.payload.strip_prefix(MAGIC.as_slice())?;
    Some(u32::from_be_bytes(version.try_into().ok()?))
}

#[cfg(test)]
mod tests {
    //! The cases of `test/dsync_core/protocol/version_handshake_test.dart`.

    use std::time::Duration;

    use tokio::io::{AsyncWriteExt, BufReader, duplex};

    use super::*;

    const DEADLINE: Duration = Duration::from_secs(5);

    /// Both ends of a connection shaking hands as `near` and `far`.
    async fn shake(near: u32, far: u32) -> (Result<(), LinkError>, Result<(), LinkError>) {
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

    #[tokio::test]
    async fn succeeds_when_both_ends_speak_the_same_version() {
        let (near, far) = shake(PROTOCOL_VERSION, PROTOCOL_VERSION).await;
        near.unwrap();
        far.unwrap();
        assert_eq!(PROTOCOL_VERSION, 1);
    }

    #[tokio::test]
    async fn fails_both_ends_when_the_versions_differ() {
        let (near, far) = shake(1, 2).await;
        assert!(matches!(
            near,
            Err(LinkError::VersionMismatch {
                local: 1,
                remote: 2
            })
        ));
        assert!(matches!(
            far,
            Err(LinkError::VersionMismatch {
                local: 2,
                remote: 1
            })
        ));
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
