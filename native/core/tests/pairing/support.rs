//! Fixtures for the pairing tests: hosts with their own state dir,
//! identity and paired-device store, and an enrolment listener showing a
//! code on loopback whose operator the test plays.

use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::{Duration, SystemTime};

use dsync_core::{
    DeviceIdentity, EnrolError, EnrolmentDialer, EnrolmentEnd, EnrolmentEvent, EnrolmentListener,
    PairedDevice, PairedDeviceStore, PendingEnrolment, StateDir,
};
use dsync_domain::{PairingPayload, PeerName, Tuning};
use tempfile::TempDir;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

/// Every real-time async test's own deadline: a few seconds, far above
/// what any of them takes.
pub const DEADLINE: Duration = Duration::from_secs(5);

pub async fn with_deadline<T>(label: &str, work: impl Future<Output = T>) -> T {
    tokio::time::timeout(DEADLINE, work)
        .await
        .unwrap_or_else(|_| panic!("{label} did not finish within {DEADLINE:?}"))
}

/// Where the showing device says it serves peer:// (never dialled here).
pub const SERVICE_PORT: u16 = 29000;

pub fn name(text: &str) -> PeerName {
    PeerName::parse(text).unwrap()
}

pub fn loopback() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)
}

/// One installation: its state dir, identity and paired-device store.
pub struct Host {
    _dir: TempDir,
    pub identity: DeviceIdentity,
    pub store: PairedDeviceStore,
}

impl Host {
    pub fn new(common_name: &str) -> Host {
        let dir = tempfile::tempdir().unwrap();
        let store = PairedDeviceStore::new(&StateDir::new(dir.path()));
        Host {
            _dir: dir,
            identity: DeviceIdentity::generate(common_name, SystemTime::now()).unwrap(),
            store,
        }
    }

    pub fn paired(&self) -> Vec<PairedDevice> {
        self.store.load().unwrap().iter().cloned().collect()
    }

    pub async fn enrol(
        &self,
        payload: &PairingPayload,
        label: &str,
    ) -> Result<PairedDevice, EnrolError> {
        EnrolmentDialer::new(self.identity.clone(), self.store.clone(), Tuning::DEFAULT)
            .enrol(payload, name(label))
            .await
    }
}

/// An enrolment listener serving on loopback, the operator's questions
/// (answered by the test) and the connections it turned away.
pub struct Showing {
    pub payload: PairingPayload,
    pub at: SocketAddr,
    pub asked: mpsc::UnboundedReceiver<(PendingEnrolment, oneshot::Sender<bool>)>,
    pub events: mpsc::UnboundedReceiver<EnrolmentEvent>,
    task: JoinHandle<std::io::Result<EnrolmentEnd>>,
}

impl Showing {
    /// The next enrolment put to the operator, and the way to answer it.
    pub async fn next_question(&mut self) -> (PendingEnrolment, oneshot::Sender<bool>) {
        with_deadline("the next question to the operator", self.asked.recv())
            .await
            .expect("the listener is running")
    }

    pub async fn next_event(&mut self) -> EnrolmentEvent {
        with_deadline("the next listener event", self.events.recv())
            .await
            .expect("the listener is running")
    }

    /// How the pairing ended.
    pub async fn ended(&mut self) -> EnrolmentEnd {
        with_deadline("the end of the pairing", &mut self.task)
            .await
            .unwrap()
            .unwrap()
    }

    pub fn is_open(&self) -> bool {
        !self.task.is_finished()
    }
}

impl Drop for Showing {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// `host` shows a code, naming whoever enrols `label`.
pub async fn show(host: &Host, label: &str) -> Showing {
    show_with(host, label, Tuning::DEFAULT).await
}

pub async fn show_with(host: &Host, label: &str, tuning: Tuning) -> Showing {
    let listener = EnrolmentListener::bind(
        loopback(),
        host.identity.clone(),
        host.store.clone(),
        name(label),
        tuning,
    )
    .await
    .unwrap();
    let at = listener.local_addr().unwrap();
    let payload = listener.payload("127.0.0.1", SERVICE_PORT).unwrap();
    let (ask, asked) = mpsc::unbounded_channel();
    let (report, events) = mpsc::unbounded_channel();
    let task = tokio::spawn(listener.serve(
        move |pending| {
            let (answer, answered) = oneshot::channel();
            let _ = ask.send((pending, answer));
            async move { answered.await.unwrap_or(false) }
        },
        move |event| {
            let _ = report.send(event);
        },
    ));
    Showing {
        payload,
        at,
        asked,
        events,
        task,
    }
}

/// `host` enrols with `showing`'s code as `label`, the operator confirming.
pub async fn enrol_confirmed(
    host: &Host,
    showing: &mut Showing,
    label: &str,
) -> Result<PairedDevice, EnrolError> {
    let payload = showing.payload.clone();
    let (enrolled, ()) = with_deadline("the confirmed enrolment", async {
        tokio::join!(host.enrol(&payload, label), async {
            showing.next_question().await.1.send(true).unwrap();
        })
    })
    .await;
    enrolled
}
