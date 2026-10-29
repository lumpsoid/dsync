//! A network path a test can break: a loopback TCP relay to `target`,
//! dialled in place of it. Each connection it accepts is relayed through
//! its own pair of pumps, so a test can drop the link out from under a
//! session the way a Wi-Fi drop or a roam does:
//!
//! - [`CutLink::cut`] closes both sockets of every relayed connection;
//! - [`CutLink::black_hole`] stops forwarding both ways and keeps the
//!   sockets open - the relay stops reading, so the senders' buffers fill
//!   and neither end hears anything, as on a dead path;
//! - [`CutLink::refuse`] / [`CutLink::admit`] turn new connects away
//!   (refused at the socket: nothing listens) and back.
//!
//! Only the connections relayed so far are cut or black-holed; one made
//! after relays normally, as a re-dial over a new path would.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::task::JoinHandle;

pub struct CutLink {
    /// Where to dial.
    pub at: SocketAddr,
    relayed: Arc<Mutex<Vec<Relayed>>>,
    /// Black-holed connections, their sockets held open until the relay
    /// is dropped.
    holes: Mutex<Vec<Relayed>>,
    admitting: watch::Sender<bool>,
    /// Whether a socket is listening at `at` now.
    listening: watch::Receiver<bool>,
    accepting: JoinHandle<()>,
}

/// One relayed connection: its two pumps, and whether they forward.
struct Relayed {
    pumps: [JoinHandle<()>; 2],
    held: watch::Sender<bool>,
}

impl CutLink {
    pub async fn to(target: SocketAddr) -> CutLink {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let at = listener.local_addr().unwrap();
        let relayed = Arc::new(Mutex::new(Vec::new()));
        let (admitting, admitted) = watch::channel(true);
        let (bound, listening) = watch::channel(true);
        let accepting = tokio::spawn(accept(
            listener,
            at,
            target,
            relayed.clone(),
            admitted,
            bound,
        ));
        CutLink {
            at,
            relayed,
            holes: Mutex::new(Vec::new()),
            admitting,
            listening,
            accepting,
        }
    }

    /// Closes both sockets of every connection relayed so far.
    pub fn cut(&self) {
        for relayed in self.take() {
            for pump in relayed.pumps {
                pump.abort();
            }
        }
    }

    /// Stops forwarding either way on every connection relayed so far,
    /// holding its sockets open and unread.
    pub fn black_hole(&self) {
        let held = self.take();
        for relayed in &held {
            relayed.held.send_replace(true);
        }
        self.holes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .extend(held);
    }

    /// Turns new connects away until [`CutLink::admit`]; returns once
    /// nothing listens.
    pub async fn refuse(&self) {
        self.admitting.send_replace(false);
        self.listening_is(false).await;
    }

    /// Returns once a socket listens at [`CutLink::at`] again.
    pub async fn admit(&self) {
        self.admitting.send_replace(true);
        self.listening_is(true).await;
    }

    async fn listening_is(&self, wanted: bool) {
        let mut listening = self.listening.clone();
        listening
            .wait_for(|now| *now == wanted)
            .await
            .expect("the relay is accepting");
    }

    fn take(&self) -> Vec<Relayed> {
        std::mem::take(&mut *self.relayed.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

impl Drop for CutLink {
    fn drop(&mut self) {
        self.accepting.abort();
        self.cut();
        let holes = std::mem::take(&mut *self.holes.lock().unwrap_or_else(PoisonError::into_inner));
        for relayed in holes {
            for pump in relayed.pumps {
                pump.abort();
            }
        }
    }
}

async fn accept(
    listener: TcpListener,
    at: SocketAddr,
    target: SocketAddr,
    relayed: Arc<Mutex<Vec<Relayed>>>,
    mut admitted: watch::Receiver<bool>,
    bound: watch::Sender<bool>,
) {
    let mut listener = Some(listener);
    loop {
        let Some(open) = &listener else {
            // Refusing: nothing listens until admitted again.
            if admitted.wait_for(|admit| *admit).await.is_err() {
                return;
            }
            listener = Some(TcpListener::bind(at).await.unwrap());
            bound.send_replace(true);
            continue;
        };
        let accepted = tokio::select! {
            accepted = open.accept() => accepted,
            refused = admitted.wait_for(|admit| !*admit) => {
                if refused.is_err() {
                    return;
                }
                listener = None;
                bound.send_replace(false);
                continue;
            }
        };
        let Ok((near, _)) = accepted else { return };
        let Ok(far) = TcpStream::connect(target).await else {
            continue;
        };
        let _ = (near.set_nodelay(true), far.set_nodelay(true));
        let (held, holding) = watch::channel(false);
        let (near_read, near_write) = near.into_split();
        let (far_read, far_write) = far.into_split();
        let pumps = [
            tokio::spawn(pump(near_read, far_write, holding.clone())),
            tokio::spawn(pump(far_read, near_write, holding)),
        ];
        relayed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(Relayed { pumps, held });
    }
}

/// Forwards `from` to `to` until either ends, reading nothing while
/// `held`. The other direction keeps its own pump: a half-closed side
/// shuts its peer's write half, as TCP would.
async fn pump(mut from: OwnedReadHalf, mut to: OwnedWriteHalf, mut held: watch::Receiver<bool>) {
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        if held.wait_for(|held| !*held).await.is_err() {
            return;
        }
        let read = tokio::select! {
            read = from.read(&mut buffer) => read,
            _ = held.wait_for(|held| *held) => continue,
        };
        match read {
            Ok(0) | Err(_) => {
                let _ = to.shutdown().await;
                return;
            }
            Ok(read) => {
                if held.wait_for(|held| !*held).await.is_err() {
                    return;
                }
                if to.write_all(&buffer[..read]).await.is_err() {
                    return;
                }
            }
        }
    }
}
