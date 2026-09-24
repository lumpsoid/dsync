//! Pairing (SPEC §4.4), both ways round: a pairing window this device
//! shows (`dsync pair show`), confirmed by the operator through the head,
//! and redeeming another device's code (`dsync pair accept`).

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::SystemTime;

use dsync_core::{
    Certificate, EnrolmentDialer, EnrolmentEnd, EnrolmentEvent, EnrolmentListener,
    PendingEnrolment, interface_addresses, read_pair_code,
};
use dsync_domain::host_port::parse_bind_address;
use dsync_domain::{PairCode, PairingPayload, PeerName, advertised_host};
use tokio::sync::oneshot;

use crate::dispatch::{Handled, Hub, text};
use crate::outbox::Outbox;
use crate::sessions::{PairingControl, Session};
use crate::signals::{EnrolmentUpdateBody, ReplyResult};
use crate::views::{DeviceView, EnrolmentEndView, PairCodeView, PairingShownView};

/// Where the operator's answer goes while a device waits for it.
type Answer = Arc<Mutex<Option<oneshot::Sender<bool>>>>;

impl Hub {
    /// Binds the enrolment listener and answers with the payload; the
    /// window's story goes out as `session`'s [`EnrolmentUpdateBody`]s. It
    /// closes when a device enrols or is refused, the token expires, or
    /// it is cancelled.
    pub(crate) async fn show_pairing(
        &self,
        session: u64,
        name: &str,
        bind: &str,
        advertise: Option<String>,
        service_port: u16,
    ) -> Handled {
        let name = PeerName::parse(name).map_err(text)?;
        let bind = parse_bind_address(bind).map_err(text)?;
        let identity = self
            .identities()
            .load_or_create(&self.device_name, SystemTime::now())
            .map_err(text)?;
        let device_id = identity.device_id().to_string();
        let listener = EnrolmentListener::bind(
            SocketAddr::new(bind, 0),
            identity,
            self.paired(),
            name,
            self.tuning,
        )
        .await
        .map_err(text)?;
        // An unreadable interface list is only a worse guess.
        let interfaces = interface_addresses().unwrap_or_default();
        let host = advertised_host(advertise.as_deref(), bind, &interfaces);
        let payload = listener.payload(&host, service_port).map_err(text)?;

        let answer = Answer::default();
        let confirm = {
            let (answer, out) = (answer.clone(), self.out.clone());
            move |pending: PendingEnrolment| {
                let (answered, awaited) = oneshot::channel();
                *answer.lock().unwrap_or_else(PoisonError::into_inner) = Some(answered);
                out.enrolment(
                    session,
                    EnrolmentUpdateBody::Awaiting {
                        from: pending.from.to_string(),
                        device_id: pending.device.to_string(),
                        name: pending.name.to_string(),
                    },
                );
                // Nobody left to answer is nobody who agreed.
                async move { awaited.await.unwrap_or(false) }
            }
        };
        let refused = {
            let out = self.out.clone();
            move |EnrolmentEvent::Refused { from, why }| {
                out.enrolment(
                    session,
                    EnrolmentUpdateBody::Refused {
                        from: from.to_string(),
                        message: why.to_string(),
                    },
                );
            }
        };
        let out = self.out.clone();
        let pending = answer.clone();
        self.sessions.spawn(
            session,
            |task| Session::Pairing(PairingControl { task, pending }),
            async move {
                let ended = listener.serve(confirm, refused).await;
                out.enrolment(session, EnrolmentUpdateBody::Ended(ended_view(ended)));
            },
        );
        Ok(ReplyResult::PairingShown(PairingShownView {
            endpoint: payload.address().to_string(),
            payload: payload.encode(),
            device_id,
            expires_in_seconds: self.tuning.pairing_token.as_secs(),
        }))
    }

    /// The operator's answer for the device waiting in `session`.
    pub(crate) fn confirm_pairing(&self, session: u64, accept: bool) -> Handled {
        let answered = self
            .sessions
            .with(session, |live| match live {
                Session::Pairing(control) => control
                    .pending
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .take(),
                Session::Run(_) | Session::Serve(_) => None,
            })
            .flatten()
            .ok_or_else(|| format!("no device is waiting to be confirmed in session {session}"))?;
        // A window that expired meanwhile has stopped listening; its end
        // says so.
        let _ = answered.send(accept);
        Ok(ReplyResult::Done)
    }

    /// Closes the window: the listener goes with its task.
    pub(crate) fn cancel_pairing(&self, session: u64) -> Handled {
        let live = self
            .sessions
            .take_if(session, |live| matches!(live, Session::Pairing(_)));
        cancel(&self.out, live, session)
    }

    pub(crate) fn read_pair_code(&self, text_form: &str) -> ReplyResult {
        ReplyResult::PairCode(match read_pair_code(text_form.trim()) {
            PairCode::Unreadable(error) => PairCodeView::Unreadable {
                message: error.to_string(),
            },
            PairCode::Read(read) => PairCodeView::Read {
                desktop_name: read.desktop_name().to_owned(),
                address: read.address().to_string(),
                device_id: Certificate::from_der(read.payload().certificate_der().to_vec())
                    .ok()
                    .map(|certificate| certificate.device_id().to_string()),
            },
        })
    }

    /// Redeems `code`, recording the showing device as `name` on both
    /// sides once its operator confirms.
    pub(crate) async fn accept_pairing(&self, code: &str, name: &str) -> Handled {
        let name = PeerName::parse(name).map_err(text)?;
        let payload = PairingPayload::decode(code.trim()).map_err(text)?;
        let identity = self
            .identities()
            .load_or_create(&self.device_name, SystemTime::now())
            .map_err(text)?;
        let paired = EnrolmentDialer::new(identity, self.paired(), self.tuning)
            .enrol(&payload, name)
            .await
            .map_err(text)?;
        Ok(ReplyResult::Device(DeviceView::of(
            &paired,
            SystemTime::now(),
        )))
    }
}

fn cancel(out: &Outbox, live: Option<Session>, session: u64) -> Handled {
    match live {
        Some(Session::Pairing(control)) => {
            control.task.abort();
            out.enrolment(
                session,
                EnrolmentUpdateBody::Ended(EnrolmentEndView::Cancelled),
            );
            Ok(ReplyResult::Done)
        }
        _ => Err(format!("no pairing window is open in session {session}")),
    }
}

fn ended_view(ended: std::io::Result<EnrolmentEnd>) -> EnrolmentEndView {
    match ended {
        Ok(EnrolmentEnd::Enrolled(device)) => {
            EnrolmentEndView::Enrolled(DeviceView::of(&device, SystemTime::now()))
        }
        Ok(EnrolmentEnd::Declined { device }) => EnrolmentEndView::Declined {
            device_id: device.to_string(),
        },
        Ok(EnrolmentEnd::Unconfirmed { device }) => EnrolmentEndView::Unconfirmed {
            device_id: device.to_string(),
        },
        Ok(EnrolmentEnd::NotStored { device, error }) => EnrolmentEndView::NotStored {
            device_id: device.to_string(),
            message: error.to_string(),
        },
        Ok(EnrolmentEnd::Expired) => EnrolmentEndView::Expired,
        Err(error) => EnrolmentEndView::Failed {
            message: error.to_string(),
        },
    }
}
