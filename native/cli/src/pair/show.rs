//! `dsync pair show` (SPEC §4.4): bind the enrolment listener, print this
//! device's payload, and wait for one device to redeem it - confirmed by
//! the operator at a y/n prompt before anything is recorded.
//!
//! The endpoint exists only while this command runs: bound here, closed
//! when the serve future is dropped, on every path including a signal.
//! stdout carries the payload line and nothing else (what `pair accept`
//! and a wrapper script read); the QR and every line of commentary go to
//! stderr.

use std::io::{self, IsTerminal, Write};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::SystemTime;

use dsync_core::{
    DeviceIdentityStore, EnrolmentBindError, EnrolmentEnd, EnrolmentEvent, EnrolmentListener,
    EnrolmentRefusal, PairedDeviceStore, PendingEnrolment, interface_addresses,
};
use dsync_domain::{Tuning, advertised_host};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader, Lines};
use tokio::sync::Mutex;

use super::{peer_name, state_dir};
use crate::args::PairShowArgs;
use crate::failure::Failure;
use crate::host::Host;
use crate::qr::{render_pairing_qr, terminal_supported};
use crate::stop::{STOP_DEADLINE, StopSequence, exit_process, os_signals};

/// Pairing cannot complete without an answer at the prompt, so a run with
/// nobody behind stdin would bind, print, and then refuse whoever came.
const NO_ONE_TO_CONFIRM: &str = "dsync pair show: stdin is not a terminal, so there is \
                                     nobody to confirm the device that redeems this payload \
                                     (SPEC §4.4). Run it from a terminal, or pair the other way \
                                     round with `dsync pair accept` on this device.";

pub async fn show(args: PairShowArgs, host: &Host) -> Result<u8, Failure> {
    let name = peer_name(
        &args.name,
        "dsync pair show needs --name: this host's own label for the device that redeems the \
         payload.",
    )?;
    let bind = args.bind()?;
    let state = state_dir(&args.state, host)?;
    if !io::stdin().is_terminal() {
        return Err(Failure::Fatal(NO_ONE_TO_CONFIRM.to_owned()));
    }
    let identity = DeviceIdentityStore::new(&state)
        .load_or_create(&Host::name(), SystemTime::now())
        .map_err(|error| Failure::Fatal(format!("dsync pair show: {error}")))?;
    let this_device = identity.device_id();
    let tuning = Tuning::DEFAULT;
    let listener = EnrolmentListener::bind(
        SocketAddr::new(bind, 0),
        identity,
        PairedDeviceStore::new(&state),
        name,
        tuning,
    )
    .await
    .map_err(bind_failure)?;
    // Trapped before anything is printed: the listener closes with this
    // command on every path.
    let signals = os_signals().map_err(|error| {
        Failure::Fatal(format!("dsync pair show: cannot trap signals: {error}"))
    })?;
    let stop = StopSequence::watch(signals, STOP_DEADLINE, exit_process);

    // An unreadable interface list is only a worse guess.
    let interfaces = interface_addresses().unwrap_or_default();
    let advertised = advertised_host(args.advertise.as_deref(), bind, &interfaces);
    let payload = listener
        .payload(&advertised, args.serve_port)
        .map_err(|error| Failure::Fatal(format!("dsync pair show: {error}")))?
        .encode();
    println!("{payload}");
    let _ = io::stdout().flush();
    announce(&payload, &this_device.to_string(), host, tuning);

    let input = Arc::new(Mutex::new(BufReader::new(tokio::io::stdin()).lines()));
    let ask = move |pending: PendingEnrolment| {
        let input = input.clone();
        async move { confirm(&pending, &mut *input.lock().await, &mut io::stderr()).await }
    };
    let ended = tokio::select! {
        signal = stop.requested() => {
            stop.release();
            return Ok(signal.exit_code());
        }
        ended = listener.serve(ask, report) => ended,
    };
    stop.release();
    match ended.map_err(|error| Failure::Fatal(format!("dsync pair show: {error}")))? {
        EnrolmentEnd::Enrolled(device) => {
            eprintln!(
                "dsync pair show: paired with \"{name}\" ({}). Grant it a replica root with \
                 `dsync pair grant \"{name}\" <path>` before it can reach anything (SPEC §4.4).",
                device.device_id(),
                name = device.name(),
            );
            Ok(0)
        }
        EnrolmentEnd::Declined { device } => Err(refused(format!(
            "device {device} was declined here; nothing was recorded."
        ))),
        EnrolmentEnd::Unconfirmed { device } => Err(refused(format!(
            "nobody confirmed device {device} before the token expired; nothing was recorded."
        ))),
        EnrolmentEnd::NotStored { device, error } => Err(refused(format!(
            "device {device} was confirmed but could not be recorded: {error}"
        ))),
        EnrolmentEnd::Expired => Err(Failure::Fatal(
            "dsync pair show: no device enrolled before the token expired. Run `dsync pair \
             show` again for a fresh one."
                .to_owned(),
        )),
    }
}

/// The commentary under the payload line, and the QR when the terminal
/// can draw one; the text line above is always enough to pair.
fn announce(payload: &str, this_device: &str, host: &Host, tuning: Tuning) {
    let drawable = terminal_supported(io::stderr().is_terminal(), host.facts.var("TERM"));
    let mut err = io::stderr().lock();
    let _ = writeln!(
        err,
        "dsync pair show: this device is {this_device}. Waiting up to {} minutes for one device \
         to redeem the payload above — paste it into `dsync pair accept` on the other \
         device{}. Ctrl-C cancels.",
        tuning.pairing_token.as_secs() / 60,
        if drawable {
            ", or scan the QR below"
        } else {
            ""
        }
    );
    let _ = if !drawable {
        writeln!(
            err,
            "dsync pair show: this terminal is not detected as supporting the Unicode block \
             characters a QR needs — paste the payload line above into `dsync pair accept` \
             instead."
        )
    } else {
        match render_pairing_qr(payload) {
            Ok(symbol) => writeln!(err, "\n{symbol}\n"),
            Err(_) => writeln!(
                err,
                "dsync pair show: this pairing payload is too large to render as a QR — paste \
                 the payload line above into `dsync pair accept` instead."
            ),
        }
    };
}

/// SPEC §4.4's out-of-band check: the id of whoever redeemed the payload,
/// and a `y` or an `n`. Anything else asks again; input that ends first is
/// a refusal - nobody left to ask is nobody who agreed.
async fn confirm<R: AsyncBufRead + Unpin>(
    pending: &PendingEnrolment,
    input: &mut Lines<R>,
    out: &mut impl Write,
) -> bool {
    let _ = writeln!(
        out,
        "\ndsync pair show: a device redeemed the payload and says it is:\n  {}\nCheck that \
         against the id \"{}\" shows on its own screen — `dsync pair accept` prints it as it \
         connects. Pair only if every group matches; if they do not, somebody else got there \
         first (SPEC §4.4).",
        pending.device, pending.name
    );
    loop {
        let _ = write!(out, "  [y] pair  [n] refuse > ");
        let _ = out.flush();
        let Ok(Some(line)) = input.next_line().await else {
            let _ = writeln!(out);
            return false;
        };
        match line.trim().to_lowercase().as_str() {
            "y" => return true,
            "n" => return false,
            _ => {
                let _ = writeln!(out, "Not understood: \"{line}\". Enter y or n.");
            }
        }
    }
}

/// A connection turned away before it spent the token. Only a token
/// refusal is the operator's news - someone had a payload, wrong or
/// stale; a scan or a bare probe is not.
fn report(event: EnrolmentEvent) {
    let EnrolmentEvent::Refused { from, why } = event;
    if let EnrolmentRefusal::Token(_) = why {
        eprintln!("dsync pair show: refused {from}: {why}");
    }
}

fn refused(why: String) -> Failure {
    Failure::Fatal(format!("dsync pair show: enrolment refused: {why}"))
}

/// Loud, naming what was asked for, with no fallback: an endpoint on
/// another address would advertise one nothing answers on.
fn bind_failure(error: EnrolmentBindError) -> Failure {
    let message = match error {
        EnrolmentBindError::Listen(error) => format!(
            "could not open the pairing endpoint on {}: {}. This host does not hold that \
             address right now, or — for :: — has IPv6 disabled. Nothing was bound and no \
             payload was printed.",
            error.address.ip(),
            error.source
        ),
        other => format!("{other}. No payload was printed."),
    };
    Failure::Fatal(format!("dsync pair show: {message}"))
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;

    use dsync_domain::{DeviceId, PeerName};

    use super::*;
    use crate::test_support::with_deadline;

    fn pending() -> PendingEnrolment {
        PendingEnrolment {
            from: SocketAddr::from(([127, 0, 0, 1], 1)),
            device: DeviceId::from_spki_der(b"spki"),
            name: PeerName::parse("phone").unwrap(),
        }
    }

    async fn answer(typed: &str) -> (bool, String) {
        let mut out = Vec::new();
        let mut input = BufReader::new(typed.as_bytes()).lines();
        let answer = with_deadline("confirm", confirm(&pending(), &mut input, &mut out)).await;
        (answer, String::from_utf8(out).unwrap())
    }

    #[tokio::test]
    async fn y_pairs_and_the_prompt_shows_the_redeeming_device() {
        let (answer, said) = answer("y\n").await;
        assert!(answer);
        assert!(said.contains("redeemed the payload"), "{said}");
        assert!(said.contains(&pending().device.to_string()), "{said}");
        assert!(said.contains("\"phone\""), "{said}");
    }

    #[tokio::test]
    async fn n_refuses() {
        assert!(!answer("n\n").await.0);
    }

    #[tokio::test]
    async fn anything_else_asks_again() {
        let (answer, said) = answer("maybe\nY\n").await;
        assert!(answer);
        assert!(said.contains("Not understood: \"maybe\""), "{said}");
    }

    #[tokio::test]
    async fn input_that_ends_unanswered_refuses() {
        assert!(!answer("").await.0);
        assert!(!answer("maybe\n").await.0);
    }
}
