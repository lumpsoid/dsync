//! The enrolment exchange's own wire shape (SPEC §4.4): one request, one
//! reply, one connection, then closed. Deliberately not the replica
//! protocol's frames, so nothing on an enrolment socket - reached by
//! devices that are not paired - can be mistaken for, or routed into, the
//! protocol only paired devices reach.
//!
//! Each message is a big-endian `u32` length and a postcard body, capped
//! at [`MAX_ENROLMENT_MESSAGE_BYTES`]: the request is read before anything
//! has authenticated the peer, so the announced length is refused before a
//! byte of body is buffered for it.

use std::io;
use std::num::NonZeroU16;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use dsync_domain::EnrolmentToken;

/// Far above a token and a certificate (a few hundred bytes), and a
/// constant rather than tuning: no caller has earned the right to make an
/// unauthenticated peer's message bigger.
pub(crate) const MAX_ENROLMENT_MESSAGE_BYTES: u32 = 64 * 1024;

/// What the enrolling device sends: the token, as proof it saw the
/// payload, its own certificate, and the port it serves paired devices
/// on, where the listener will dial it at the address it connected from.
/// No name: each side names its peer itself (SPEC §4.4, task 736fdb), so
/// there is nothing to propose. A port of 0 does not decode: such a
/// request is malformed.
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
pub(crate) struct EnrolmentRequest {
    pub(crate) token: [u8; EnrolmentToken::LEN],
    pub(crate) certificate_der: Vec<u8>,
    pub(crate) serves_on: NonZeroU16,
}

/// The listener's one answer.
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
pub(crate) enum EnrolmentReply {
    /// Confirmed and recorded on the listener's side.
    Accepted,
    Denied(EnrolmentDenial),
}

/// Why the listener did not enrol this device, as told to it. Coarser than
/// the listener's own [`crate::EnrolmentRefusal`]: every way the token can
/// fail is one answer, so a peer learns nothing about the token by asking.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum EnrolmentDenial {
    #[error("the pairing code was not accepted: it is wrong, already used or expired")]
    TokenRejected,
    #[error("the device showing the code could not read this device's certificate")]
    UnreadableCertificate,
    #[error("the pairing was declined on the device showing the code")]
    Declined,
    #[error("nobody confirmed the pairing on the device showing the code before it expired")]
    Unconfirmed,
    #[error("the device showing the code could not record the pairing; see its screen")]
    NotStored,
}

#[derive(Debug, thiserror::Error)]
pub enum EnrolmentMessageError {
    #[error("the message announces {0} bytes, over the {MAX_ENROLMENT_MESSAGE_BYTES}-byte cap")]
    TooLarge(u32),
    #[error("the connection closed before a whole message arrived")]
    Closed,
    #[error("not an enrolment message: {0}")]
    Malformed(postcard::Error),
    #[error("{0} bytes follow the message")]
    TrailingBytes(usize),
    #[error(transparent)]
    Io(io::Error),
}

pub(crate) async fn write_message<T: Serialize>(
    stream: &mut (impl AsyncWrite + Unpin),
    message: &T,
) -> io::Result<()> {
    let body = postcard::to_stdvec(message).map_err(io::Error::other)?;
    let len = u32::try_from(body.len()).map_err(io::Error::other)?;
    let mut framed = Vec::with_capacity(body.len() + 4);
    framed.extend_from_slice(&len.to_be_bytes());
    framed.extend_from_slice(&body);
    stream.write_all(&framed).await?;
    stream.flush().await
}

pub(crate) async fn read_message<T: DeserializeOwned>(
    stream: &mut (impl AsyncRead + Unpin),
) -> Result<T, EnrolmentMessageError> {
    let mut header = [0u8; 4];
    read_exact(stream, &mut header).await?;
    let len = u32::from_be_bytes(header);
    if len > MAX_ENROLMENT_MESSAGE_BYTES {
        return Err(EnrolmentMessageError::TooLarge(len));
    }
    let mut body = vec![0u8; len as usize];
    read_exact(stream, &mut body).await?;
    match postcard::take_from_bytes(&body) {
        Ok((message, [])) => Ok(message),
        Ok((_, rest)) => Err(EnrolmentMessageError::TrailingBytes(rest.len())),
        Err(e) => Err(EnrolmentMessageError::Malformed(e)),
    }
}

async fn read_exact(
    stream: &mut (impl AsyncRead + Unpin),
    into: &mut [u8],
) -> Result<(), EnrolmentMessageError> {
    match stream.read_exact(into).await {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Err(EnrolmentMessageError::Closed),
        Err(e) => Err(EnrolmentMessageError::Io(e)),
    }
}

#[cfg(test)]
mod tests {
    //! The cases of `test/dsync_core/identity/enrolment_message_test.dart`
    //! that apply to a length-prefixed read (a body is read exactly, so
    //! "more bytes than the cap accumulated" cannot happen).

    use tokio::io::duplex;

    use super::*;

    fn request() -> EnrolmentRequest {
        EnrolmentRequest {
            token: [7; EnrolmentToken::LEN],
            certificate_der: vec![1, 2, 3],
            serves_on: NonZeroU16::new(40123).unwrap(),
        }
    }

    #[tokio::test]
    async fn a_complete_message_round_trips() {
        let (mut a, mut b) = duplex(1024);
        write_message(&mut a, &request()).await.unwrap();
        let read: EnrolmentRequest = read_message(&mut b).await.unwrap();
        assert_eq!(read, request());
        write_message(&mut b, &EnrolmentReply::Denied(EnrolmentDenial::Declined))
            .await
            .unwrap();
        let reply: EnrolmentReply = read_message(&mut a).await.unwrap();
        assert_eq!(reply, EnrolmentReply::Denied(EnrolmentDenial::Declined));
    }

    #[tokio::test]
    async fn a_message_closed_before_it_completes_is_refused() {
        let (mut a, mut b) = duplex(1024);
        a.write_all(&10u32.to_be_bytes()).await.unwrap();
        a.write_all(&[1, 2, 3]).await.unwrap();
        drop(a);
        let read = read_message::<EnrolmentRequest>(&mut b).await;
        assert!(
            matches!(read, Err(EnrolmentMessageError::Closed)),
            "{read:?}"
        );
    }

    #[tokio::test]
    async fn a_length_over_the_cap_is_refused_before_any_body_arrives() {
        let (mut a, mut b) = duplex(1024);
        // The header alone, the writer kept open: the refusal cannot be
        // waiting for a body.
        a.write_all(&(MAX_ENROLMENT_MESSAGE_BYTES + 1).to_be_bytes())
            .await
            .unwrap();
        let read = read_message::<EnrolmentRequest>(&mut b).await;
        assert!(
            matches!(read, Err(EnrolmentMessageError::TooLarge(n)) if n == MAX_ENROLMENT_MESSAGE_BYTES + 1),
            "{read:?}"
        );
    }

    /// Positive control: a request exactly at the cap is read.
    #[tokio::test]
    async fn a_message_exactly_at_the_cap_is_read() {
        let cap = MAX_ENROLMENT_MESSAGE_BYTES as usize;
        // The token, a three-byte varint length, the certificate, then
        // the port's varint.
        let serves_on = NonZeroU16::new(40123).unwrap();
        let port_len = postcard::to_stdvec(&serves_on).unwrap().len();
        let padded = EnrolmentRequest {
            token: [7; EnrolmentToken::LEN],
            certificate_der: vec![1; cap - EnrolmentToken::LEN - 3 - port_len],
            serves_on,
        };
        assert_eq!(postcard::to_stdvec(&padded).unwrap().len(), cap);
        let (mut a, mut b) = duplex(2 * cap);
        write_message(&mut a, &padded).await.unwrap();
        let read: EnrolmentRequest = read_message(&mut b).await.unwrap();
        assert_eq!(read, padded);
    }

    #[tokio::test]
    async fn bytes_after_the_message_inside_its_length_are_refused() {
        let mut body = postcard::to_stdvec(&request()).unwrap();
        body.push(0);
        let (mut a, mut b) = duplex(1024);
        a.write_all(&(body.len() as u32).to_be_bytes())
            .await
            .unwrap();
        a.write_all(&body).await.unwrap();
        let read = read_message::<EnrolmentRequest>(&mut b).await;
        assert!(
            matches!(read, Err(EnrolmentMessageError::TrailingBytes(1))),
            "{read:?}"
        );
    }

    /// The request's layout with a plain port, which nothing but a
    /// hand-rolled peer would send as 0.
    #[derive(Serialize)]
    struct AnyPortRequest {
        token: [u8; EnrolmentToken::LEN],
        certificate_der: Vec<u8>,
        serves_on: u16,
    }

    #[tokio::test]
    async fn a_request_serving_on_port_zero_is_malformed() {
        let zero = AnyPortRequest {
            token: [7; EnrolmentToken::LEN],
            certificate_der: vec![1, 2, 3],
            serves_on: 0,
        };
        let (mut a, mut b) = duplex(1024);
        write_message(&mut a, &zero).await.unwrap();
        let read = read_message::<EnrolmentRequest>(&mut b).await;
        assert!(
            matches!(read, Err(EnrolmentMessageError::Malformed(_))),
            "{read:?}"
        );

        // Positive control: the same layout with a port reads.
        let (mut a, mut b) = duplex(1024);
        write_message(
            &mut a,
            &AnyPortRequest {
                serves_on: 40123,
                ..zero
            },
        )
        .await
        .unwrap();
        let read: EnrolmentRequest = read_message(&mut b).await.unwrap();
        assert_eq!(read, request());
    }

    #[tokio::test]
    async fn a_body_that_is_not_a_request_is_malformed() {
        let (mut a, mut b) = duplex(1024);
        a.write_all(&2u32.to_be_bytes()).await.unwrap();
        a.write_all(&[0xff, 0xff]).await.unwrap();
        let read = read_message::<EnrolmentRequest>(&mut b).await;
        assert!(
            matches!(read, Err(EnrolmentMessageError::Malformed(_))),
            "{read:?}"
        );
    }
}
