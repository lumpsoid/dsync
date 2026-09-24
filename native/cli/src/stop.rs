//! How a long-running command stops (SPEC §11.5): the first SIGINT or
//! SIGTERM asks, a second one of either kind exits at once, and a deadline
//! armed by the first exits anyway. Every exit carries the *first*
//! signal's code (130 or 143). One owner, [`StopSequence`], for `sync`,
//! `status`, `agent --listen` and `agent --serve` alike.

use std::future::Future;
use std::io;
use std::time::Duration;

use dsync_domain::StopSignal;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

/// How long a stop may take once asked for. Ten seconds because closing an
/// ssh replica already spends up to a few waiting out a wedged far side,
/// after the archive flush; a supervisor's kill timeout belongs above it.
pub const STOP_DEADLINE: Duration = Duration::from_secs(10);

/// The signals this platform lets a process trap: Windows has no SIGTERM
/// to watch, only Ctrl-C.
pub const TRAPPED: &[StopSignal] = if cfg!(windows) {
    &[StopSignal::Sigint]
} else {
    &[StopSignal::Sigint, StopSignal::Sigterm]
};

/// What a signal asks for, given the ones before it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Response {
    StopGracefully,
    /// Exit now, with this code: the first signal's.
    ExitNow(u8),
}

/// Remembers the first signal, the one that picks the exit code.
#[derive(Clone, Copy, Debug, Default)]
pub struct InterruptGuard {
    first: Option<StopSignal>,
}

impl InterruptGuard {
    pub fn receive(&mut self, signal: StopSignal) -> Response {
        match self.first {
            None => {
                self.first = Some(signal);
                Response::StopGracefully
            }
            Some(first) => Response::ExitNow(first.exit_code()),
        }
    }

    pub fn interrupted_by(&self) -> Option<StopSignal> {
        self.first
    }
}

/// Watches the stop signals for the life of a command. The graceful half
/// is the caller's: it awaits [`StopSequence::requested`] and winds down.
/// The other two rules call `exit`.
pub struct StopSequence {
    first: watch::Receiver<Option<StopSignal>>,
    watching: JoinHandle<()>,
}

impl StopSequence {
    /// Starts watching `signals`. `exit` ends the process (the real one
    /// never returns; a test's records the code).
    pub fn watch(
        mut signals: mpsc::Receiver<StopSignal>,
        deadline: Duration,
        exit: impl Fn(u8) + Send + 'static,
    ) -> StopSequence {
        let (announce, first) = watch::channel(None);
        let watching = tokio::spawn(async move {
            let mut guard = InterruptGuard::default();
            let expiry = tokio::time::sleep(Duration::MAX);
            tokio::pin!(expiry);
            let mut open = true;
            loop {
                tokio::select! {
                    received = signals.recv(), if open => match received {
                        None => open = false,
                        Some(signal) => match guard.receive(signal) {
                            Response::StopGracefully => {
                                expiry.as_mut().reset(tokio::time::Instant::now() + deadline);
                                let _ = announce.send(Some(signal));
                            }
                            Response::ExitNow(code) => return exit(code),
                        },
                    },
                    () = &mut expiry, if guard.interrupted_by().is_some() => {
                        if let Some(first) = guard.interrupted_by() {
                            return exit(first.exit_code());
                        }
                    }
                    else => return,
                }
            }
        });
        StopSequence { first, watching }
    }

    /// Resolves with the first signal, once one arrives.
    pub fn requested(&self) -> impl Future<Output = StopSignal> + Send + 'static {
        let mut first = self.first.clone();
        async move {
            loop {
                if let Some(signal) = *first.borrow_and_update() {
                    return signal;
                }
                if first.changed().await.is_err() {
                    return std::future::pending().await;
                }
            }
        }
    }

    /// The first signal received so far.
    pub fn interrupted_by(&self) -> Option<StopSignal> {
        *self.first.borrow()
    }

    /// The command finished on its own: nothing is armed any more.
    pub fn release(self) {
        self.watching.abort();
    }
}

/// Ends this process with `code` at once, whatever is in flight.
pub fn exit_process(code: u8) {
    std::process::exit(i32::from(code))
}

/// This process's trapped stop signals ([`TRAPPED`]), as they arrive.
/// Installing the handlers replaces the default disposition for the rest
/// of the process.
pub fn os_signals() -> io::Result<mpsc::Receiver<StopSignal>> {
    let (sender, receiver) = mpsc::channel(4);
    for &signal in TRAPPED {
        forward(signal, sender.clone())?;
    }
    Ok(receiver)
}

#[cfg(unix)]
fn forward(signal: StopSignal, sender: mpsc::Sender<StopSignal>) -> io::Result<()> {
    use tokio::signal::unix::SignalKind;
    let kind = match signal {
        StopSignal::Sigint => SignalKind::interrupt(),
        StopSignal::Sigterm => SignalKind::terminate(),
    };
    let mut arriving = tokio::signal::unix::signal(kind)?;
    tokio::spawn(async move {
        while arriving.recv().await.is_some() {
            if sender.send(signal).await.is_err() {
                return;
            }
        }
    });
    Ok(())
}

#[cfg(windows)]
fn forward(signal: StopSignal, sender: mpsc::Sender<StopSignal>) -> io::Result<()> {
    let mut arriving = tokio::signal::windows::ctrl_c()?;
    tokio::spawn(async move {
        while arriving.recv().await.is_some() {
            if sender.send(signal).await.is_err() {
                return;
            }
        }
    });
    Ok(())
}

/// The line a stopped run prints after its summary: why the exit code is
/// about to say "interrupted", and whether the stop cut the plan short.
/// `planned` actions were approved; `finished` reported an outcome.
pub fn interrupt_note(signal: StopSignal, planned: usize, finished: usize) -> String {
    let by = format!("interrupted ({})", signal.label());
    if finished == 0 {
        format!("{by} before applying any changes.")
    } else if finished < planned {
        format!(
            "{by} partway through applying — the changes already in progress finished (see \
             above); the rest of the plan was not attempted."
        )
    } else {
        format!("{by}; this run had already finished applying — see above.")
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    #[test]
    fn a_guard_starts_with_no_signal() {
        assert_eq!(InterruptGuard::default().interrupted_by(), None);
    }

    #[test]
    fn the_first_signal_asks_nicely_and_the_second_exits_with_the_first_code() {
        for (first, second, code) in [
            (StopSignal::Sigint, StopSignal::Sigint, 130),
            (StopSignal::Sigint, StopSignal::Sigterm, 130),
            (StopSignal::Sigterm, StopSignal::Sigint, 143),
            (StopSignal::Sigterm, StopSignal::Sigterm, 143),
        ] {
            let mut guard = InterruptGuard::default();
            assert_eq!(guard.receive(first), Response::StopGracefully);
            assert_eq!(guard.interrupted_by(), Some(first));
            assert_eq!(guard.receive(second), Response::ExitNow(code));
            assert_eq!(guard.receive(second), Response::ExitNow(code));
            assert_eq!(guard.interrupted_by(), Some(first));
        }
    }

    #[test]
    fn a_posix_host_traps_both_signals_and_windows_only_sigint() {
        if cfg!(windows) {
            assert_eq!(TRAPPED, [StopSignal::Sigint]);
        } else {
            assert_eq!(TRAPPED, [StopSignal::Sigint, StopSignal::Sigterm]);
        }
    }

    #[test]
    fn the_shipped_deadline_is_ten_seconds() {
        assert_eq!(STOP_DEADLINE, Duration::from_secs(10));
    }

    #[test]
    fn the_interrupt_note_says_how_far_the_apply_got() {
        assert_eq!(
            interrupt_note(StopSignal::Sigint, 0, 0),
            "interrupted (SIGINT) before applying any changes."
        );
        assert_eq!(
            interrupt_note(StopSignal::Sigterm, 5, 0),
            "interrupted (SIGTERM) before applying any changes."
        );
        assert!(
            interrupt_note(StopSignal::Sigint, 5, 2)
                .starts_with("interrupted (SIGINT) partway through applying")
        );
        assert!(
            interrupt_note(StopSignal::Sigterm, 5, 5)
                .starts_with("interrupted (SIGTERM); this run had already finished applying")
        );
    }

    type Exits = Arc<Mutex<Vec<u8>>>;

    fn sequence(deadline: Duration) -> (mpsc::Sender<StopSignal>, StopSequence, Exits) {
        let (send, receive) = mpsc::channel(4);
        let exits = Exits::default();
        let recorded = exits.clone();
        let stop = StopSequence::watch(receive, deadline, move |code| {
            recorded.lock().unwrap().push(code);
        });
        (send, stop, exits)
    }

    async fn settle() {
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test(start_paused = true)]
    async fn the_first_signal_is_reported_and_does_not_exit() {
        for (signal, code) in [(StopSignal::Sigint, 130), (StopSignal::Sigterm, 143)] {
            let (send, stop, exits) = sequence(STOP_DEADLINE);
            send.send(signal).await.unwrap();
            assert_eq!(stop.requested().await, signal);
            assert_eq!(stop.interrupted_by(), Some(signal));
            assert_eq!(signal.exit_code(), code);
            assert!(exits.lock().unwrap().is_empty());
            stop.release();
        }
    }

    #[tokio::test(start_paused = true)]
    async fn no_signal_leaves_everything_idle() {
        let (_send, stop, exits) = sequence(Duration::from_millis(10));
        tokio::time::sleep(Duration::from_secs(60)).await;
        assert_eq!(stop.interrupted_by(), None);
        assert!(exits.lock().unwrap().is_empty());
        let waiting = tokio::time::timeout(Duration::from_secs(1), stop.requested()).await;
        assert!(waiting.is_err(), "requested() resolved with no signal");
    }

    #[tokio::test(start_paused = true)]
    async fn a_second_signal_exits_at_once_with_the_first_code() {
        let (send, stop, exits) = sequence(STOP_DEADLINE);
        send.send(StopSignal::Sigterm).await.unwrap();
        stop.requested().await;
        send.send(StopSignal::Sigint).await.unwrap();
        settle().await;
        assert_eq!(*exits.lock().unwrap(), [143]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_stop_that_never_finishes_exits_at_the_deadline_with_the_signal_code() {
        for (signal, code) in [(StopSignal::Sigterm, 143), (StopSignal::Sigint, 130)] {
            let (send, stop, exits) = sequence(STOP_DEADLINE);
            send.send(signal).await.unwrap();
            stop.requested().await;
            tokio::time::sleep(STOP_DEADLINE - Duration::from_millis(1)).await;
            settle().await;
            assert!(
                exits.lock().unwrap().is_empty(),
                "exited before the deadline"
            );
            tokio::time::sleep(Duration::from_millis(2)).await;
            settle().await;
            assert_eq!(*exits.lock().unwrap(), [code]);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_stop_released_in_time_is_never_cut_short() {
        let (send, stop, exits) = sequence(STOP_DEADLINE);
        send.send(StopSignal::Sigint).await.unwrap();
        stop.requested().await;
        stop.release();
        tokio::time::sleep(STOP_DEADLINE * 2).await;
        settle().await;
        assert!(exits.lock().unwrap().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn release_before_any_signal_leaves_nothing_armed() {
        let (send, stop, exits) = sequence(Duration::from_millis(10));
        stop.release();
        let _ = send.send(StopSignal::Sigint).await;
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert!(exits.lock().unwrap().is_empty());
    }
}
