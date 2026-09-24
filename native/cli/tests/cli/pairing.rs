//! `dsync pair show` and `dsync pair accept` against each other, two
//! processes over loopback TLS, the showing side's stdin a terminal the
//! operator answers at: the cases of the Dart `pair_show_accept_e2e_test`.
//! Everything binds 127.0.0.1.

use std::time::Duration;

use dsync_core::{DeviceIdentityStore, StateDir};
use dsync_domain::{DeviceId, PairingPayload, PeerName};

use crate::support::{Pty, Site, Spawned, paired, seed_device};

const STARTUP: Duration = Duration::from_secs(10);
const DEADLINE: Duration = Duration::from_secs(20);

/// `pair show --name phone --bind 127.0.0.1` plus `extra`, stdin a terminal.
pub struct Showing {
    pub show: Spawned,
    pub pty: Pty,
    pub payload: String,
}

impl Showing {
    /// Its stderr on a pipe: no terminal there, so no QR.
    pub fn start(site: &Site, extra: &[&str]) -> Showing {
        let pty = Pty::open();
        let show = site.spawn_with(&show_args(extra), pty.stdin(), None);
        Showing::printed(show, pty)
    }

    /// Its stderr on the terminal too, as from an operator's shell.
    pub fn on_terminal(site: &Site, extra: &[&str]) -> Showing {
        let pty = Pty::open();
        let show = site.spawn_on_terminal(&show_args(extra), &pty);
        Showing::printed(show, pty)
    }

    fn printed(show: Spawned, pty: Pty) -> Showing {
        let payload = show.stdout_line(|line| line.starts_with("dsync-pair:"), STARTUP);
        Showing { show, pty, payload }
    }

    /// `pair accept --name desktop <payload>` on `local`, answered with
    /// `answer` once the prompt shows the device that redeemed it.
    pub fn accept(&mut self, local: &Site, answer: &str) -> Spawned {
        let accept = local.spawn(&["pair", "accept", "--name", "desktop", &self.payload]);
        let enrolling = accept.stderr_line(|line| line.contains("this device is"), STARTUP);
        self.show
            .stderr_line(|line| line.contains("redeemed the payload"), STARTUP);
        // The operator's check: the id under the prompt is the one the
        // accepting side printed.
        let shown = self
            .show
            .stderr_line(|line| DeviceId::parse(line.trim()).is_ok(), STARTUP);
        assert!(enrolling.contains(shown.trim()), "{enrolling} vs {shown}");
        self.pty.type_line(answer);
        accept
    }
}

fn show_args<'a>(extra: &[&'a str]) -> Vec<&'a str> {
    let mut args = vec!["pair", "show", "--name", "phone", "--bind", "127.0.0.1"];
    args.extend_from_slice(extra);
    args
}

fn identity(site: &Site) -> DeviceId {
    DeviceIdentityStore::new(&StateDir::new(site.state_dir()))
        .load()
        .unwrap()
        .expect("an identity")
        .device_id()
}

/// Pairs `local` ("desktop" there) with `remote` ("phone" there) through
/// the two commands, `remote` advertising `serve_port` for peer://.
pub fn pair(remote: &Site, local: &Site, serve_port: u16) {
    let port = serve_port.to_string();
    let mut showing = Showing::start(remote, &["--serve-port", &port]);
    let mut accept = showing.accept(local, "y");
    let (accepted, _) = accept.exit(DEADLINE);
    assert_eq!(accepted, Some(0), "{}", accept.stderr());
    let (shown, _) = showing.show.exit(DEADLINE);
    assert_eq!(shown, Some(0), "{}", showing.show.stderr());
}

#[test]
fn a_shown_payload_accepted_pairs_both_stores_and_a_terminal_gets_a_qr() {
    let (remote, local) = (Site::new(), Site::new());
    let mut showing = Showing::on_terminal(&remote, &[]);
    let mut accept = showing.accept(&local, "y");
    let (accepted, _) = accept.exit(DEADLINE);
    assert_eq!(accepted, Some(0), "{}", accept.stderr());
    let (shown, _) = showing.show.exit(DEADLINE);
    assert_eq!(shown, Some(0), "{}", showing.show.stderr());

    // stdout is the payload line and nothing else; the QR is on stderr.
    assert_eq!(showing.show.stdout(), showing.payload);
    let said = showing.show.stderr();
    assert!(
        said.contains('█') && said.contains("scan the QR below"),
        "{said}"
    );
    assert!(
        accept.stdout().starts_with("paired: \"desktop\""),
        "{}",
        accept.stdout()
    );

    // Mutual, and named by the side that chose each name; no roots yet.
    let on_local = paired(&local.state_dir());
    let desktop = on_local
        .by_name(&PeerName::parse("desktop").unwrap())
        .unwrap();
    assert_eq!(desktop.device_id(), identity(&remote));
    assert!(desktop.granted_roots().is_empty());
    let on_remote = paired(&remote.state_dir());
    let phone = on_remote.get(&identity(&local)).unwrap();
    assert_eq!(phone.name().as_str(), "phone");
    assert!(phone.granted_roots().is_empty());
}

#[test]
fn a_terminal_that_cannot_draw_blocks_gets_a_stated_note_instead_of_a_qr() {
    let (remote, local) = (Site::new(), Site::new());
    let mut showing = Showing::start(&remote, &[]);
    let mut accept = showing.accept(&local, "y");
    assert_eq!(accept.exit(DEADLINE).0, Some(0), "{}", accept.stderr());
    assert_eq!(showing.show.exit(DEADLINE).0, Some(0));
    assert_eq!(showing.show.stdout(), showing.payload);
    let said = showing.show.stderr();
    assert!(said.contains("not detected as supporting"), "{said}");
    assert!(!said.contains(['▀', '▄', '█']), "{said}");
}

#[test]
fn the_payload_carries_the_serve_port_which_is_what_the_accepting_side_keeps() {
    let (remote, local) = (Site::new(), Site::new());
    pair(&remote, &local, 29000);
    let devices = paired(&local.state_dir());
    let desktop = devices.iter().next().unwrap();
    assert_eq!(desktop.last_known_address().to_string(), "127.0.0.1:29000");
}

#[test]
fn the_payload_advertises_the_bound_address_unless_advertise_names_another() {
    let site = Site::new();
    let bound = Showing::start(&site, &[]);
    let decoded = PairingPayload::decode(&bound.payload).unwrap();
    assert_eq!(decoded.address().host(), "127.0.0.1");
    assert_eq!(decoded.service_address().port(), 28771);
    drop(bound);

    let mut advertised = Showing::start(&site, &["--advertise", "127.0.0.2"]);
    let decoded = PairingPayload::decode(&advertised.payload).unwrap();
    assert_eq!(decoded.address().host(), "127.0.0.2");
    // A signal closes the endpoint and exits with its code.
    advertised.show.signal(libc::SIGINT);
    assert_eq!(advertised.show.exit(DEADLINE).0, Some(130));
}

#[test]
fn a_device_the_operator_does_not_recognise_is_refused_and_nothing_is_recorded() {
    let (remote, local) = (Site::new(), Site::new());
    let mut showing = Showing::start(&remote, &[]);
    let mut accept = showing.accept(&local, "n");
    assert_eq!(accept.exit(DEADLINE).0, Some(3));
    assert!(
        accept.stderr().contains("enrolment refused"),
        "{}",
        accept.stderr()
    );
    assert_eq!(showing.show.exit(DEADLINE).0, Some(3));
    let said = showing.show.stderr();
    assert!(said.contains("redeemed the payload"), "{said}");
    assert!(said.contains("enrolment refused"), "{said}");
    assert!(paired(&remote.state_dir()).is_empty());
    assert!(paired(&local.state_dir()).is_empty());
}

#[test]
fn show_will_not_start_with_nobody_behind_stdin() {
    let site = Site::new();
    let refused = site.run(&show_args(&[]));
    refused.exits(3);
    assert_eq!(refused.stdout, "");
    assert!(
        refused.stderr.contains("stdin is not a terminal"),
        "{refused:#?}"
    );
}

#[test]
fn show_without_a_name_or_with_a_port_that_is_not_one_binds_nothing() {
    let site = Site::new();
    let refusals: &[&[&str]] = &[
        &["pair", "show"],
        &["pair", "show", "--name", "   "],
        &["pair", "show", "--name", "phone", "--serve-port", "http"],
        &["pair", "show", "--name", "phone", "--serve-port", "0"],
        &["pair", "show", "--name", "phone", "--serve-port", "70000"],
        &["pair", "show", "--name", "phone", "--bind", "laptop.local"],
    ];
    for args in refusals {
        let refused = site.run(args);
        assert_eq!(refused.code, Some(3), "{args:?}: {refused:#?}");
        assert_eq!(refused.stdout, "", "{args:?}");
    }
    assert!(!site.state_dir().exists(), "a refusal made state");
}

#[test]
fn a_bind_this_host_does_not_hold_fails_loudly_with_no_payload() {
    let site = Site::new();
    let pty = Pty::open();
    let mut show = site.spawn_with(
        &["pair", "show", "--name", "phone", "--bind", "192.0.2.1"],
        pty.stdin(),
        None,
    );
    assert_eq!(show.exit(DEADLINE).0, Some(3));
    assert_eq!(show.stdout(), "");
    let said = show.stderr();
    assert!(
        said.contains("192.0.2.1") && said.contains("no payload was printed"),
        "{said}"
    );
}

#[test]
fn a_name_already_paired_is_refused_before_a_code_is_shown() {
    let site = Site::new();
    seed_device(
        &site.state_dir(),
        "phone",
        &[],
        std::time::SystemTime::now(),
    );
    let pty = Pty::open();
    let mut show = site.spawn_with(&show_args(&[]), pty.stdin(), None);
    assert_eq!(show.exit(DEADLINE).0, Some(3));
    assert_eq!(show.stdout(), "");
    assert!(
        show.stderr().contains("already paired"),
        "{}",
        show.stderr()
    );
}
