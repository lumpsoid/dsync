//! Two heads meeting over loopback: one shows a pairing window, the other
//! redeems it, the first confirms; then the first serves, the second
//! probes it and runs against it - every step a hub command.

use hub::signals::{CoreCommand, EntryDraft, ProfileDraft, ReplyResult, RunIntent, RunTarget};
use hub::views::{
    PairCodeView, PairingView, ProbeOutcome, RootKindView, RunPhaseView, ServeEventView,
    ServePhaseView,
};

use crate::support::{Head, read, write};

fn show(name: &str) -> CoreCommand {
    CoreCommand::ShowPairing {
        name: name.to_owned(),
        bind: "127.0.0.1".to_owned(),
        advertise: None,
        service_port: 28771,
    }
}

/// The window a head just opened in `session`: its payload and this
/// device's id, from its first view.
async fn opened(head: &mut Head, session: u64) -> (String, String) {
    match head.pairing_view(session).await {
        PairingView::Waiting {
            payload, device_id, ..
        } => (payload, device_id),
        _ => panic!("expected the window open"),
    }
}

async fn device_id(head: &mut Head) -> String {
    match head.ok(CoreCommand::ShowIdentity).await.1 {
        ReplyResult::Identity(identity) => identity.device_id,
        _ => panic!("expected the identity"),
    }
}

/// Pairs `phone` with `desktop` through their hubs: the desktop shows,
/// the phone redeems, the desktop confirms. The desktop knows the phone
/// as "phone", the phone the desktop as "desktop".
async fn pair(desktop: &mut Head, phone: &mut Head) {
    let (session, shown) = desktop.ok(show("phone")).await;
    assert!(matches!(shown, ReplyResult::Done));
    let (payload, desktop_id) = opened(desktop, session).await;
    let phone_id = device_id(phone).await;
    let ReplyResult::PairCode(PairCodeView::Read {
        device_id: Some(read_id),
        address,
        ..
    }) = phone
        .ok(CoreCommand::ReadPairCode {
            text: format!("  {payload}\n"),
        })
        .await
        .1
    else {
        panic!("the payload should read");
    };
    assert_eq!(read_id, desktop_id);
    assert_eq!(address, "127.0.0.1:28771");

    let accept = CoreCommand::AcceptPairing {
        code: payload.clone(),
        name: "desktop".to_owned(),
    };
    let confirming = async {
        let PairingView::Confirming { device_id, name } = desktop.pairing_view(session).await
        else {
            panic!("expected a device to confirm");
        };
        assert_eq!(device_id, phone_id, "the operator compares this id");
        assert_eq!(name, "phone");
        let confirm = CoreCommand::ConfirmPairing {
            session,
            accept: true,
        };
        assert!(matches!(desktop.ok(confirm).await.1, ReplyResult::Done));
        desktop.pairing_view(session).await
    };
    let (accepted, ended) = tokio::join!(phone.ok(accept), confirming);
    let ReplyResult::Device(paired) = accepted.1 else {
        panic!("expected the paired device");
    };
    assert_eq!(paired.name, "desktop");
    assert_eq!(paired.device_id, desktop_id);
    assert!(matches!(
        ended,
        PairingView::Enrolled(ref device) if device.device_id == phone_id
    ));
}

#[tokio::test]
async fn a_code_that_is_not_a_payload_reads_as_unreadable() {
    let mut head = Head::new("phone").await;
    let read = head
        .ok(CoreCommand::ReadPairCode {
            text: "hello".to_owned(),
        })
        .await
        .1;
    assert!(matches!(
        read,
        ReplyResult::PairCode(PairCodeView::Unreadable { .. })
    ));
}

#[tokio::test]
async fn a_pairing_window_takes_no_answer_unasked_and_closes_when_cancelled() {
    let mut desktop = Head::new("desktop").await;
    let (session, _) = desktop.ok(show("phone")).await;
    opened(&mut desktop, session).await;
    // Nothing redeemed it: no answer is taken.
    let early = desktop
        .failure(CoreCommand::ConfirmPairing {
            session,
            accept: true,
        })
        .await;
    assert!(early.contains("confirmed"), "{early}");
    let cancel = CoreCommand::CancelPairing { session };
    assert!(matches!(desktop.ok(cancel).await.1, ReplyResult::Done));
    let closed = desktop.pairing_snapshot(session).await;
    assert!(matches!(closed.view, PairingView::Cancelled));
    assert!(closed.last, "the window's last snapshot");
    let late = desktop
        .failure(CoreCommand::ConfirmPairing {
            session,
            accept: true,
        })
        .await;
    assert!(late.contains("confirmed"), "{late}");
    let again = desktop
        .failure(CoreCommand::CancelPairing { session })
        .await;
    assert!(!again.is_empty());
}

#[tokio::test]
async fn a_declined_device_is_not_recorded() {
    let mut desktop = Head::new("desktop").await;
    let mut phone = Head::new("phone").await;
    let (session, _) = desktop.ok(show("phone")).await;
    let (payload, _) = opened(&mut desktop, session).await;
    let accept = CoreCommand::AcceptPairing {
        code: payload,
        name: "desktop".to_owned(),
    };
    let declining = async {
        let awaiting = desktop.pairing_view(session).await;
        assert!(matches!(awaiting, PairingView::Confirming { .. }));
        let decline = CoreCommand::ConfirmPairing {
            session,
            accept: false,
        };
        desktop.ok(decline).await;
        desktop.pairing_view(session).await
    };
    let (refused, ended) = tokio::join!(phone.ask(accept), declining);
    assert!(matches!(refused.1, ReplyResult::Failed { .. }));
    assert!(matches!(ended, PairingView::Declined { .. }));
    let ReplyResult::Devices(devices) = desktop.ok(CoreCommand::ListDevices).await.1 else {
        panic!("expected the devices");
    };
    assert!(devices.is_empty());
}

#[tokio::test]
async fn a_paired_phone_probes_and_syncs_with_the_desktop_it_serves() {
    let mut desktop = Head::new("desktop").await;
    let mut phone = Head::new("phone").await;
    pair(&mut desktop, &mut phone).await;
    let desktop_id = device_id(&mut desktop).await;
    let phone_id = device_id(&mut phone).await;

    let shared = desktop.path_text("shared");
    std::fs::create_dir_all(&shared).unwrap_or_else(|error| panic!("{error}"));
    desktop
        .ok(CoreCommand::GrantRoot {
            device_id: phone_id.clone(),
            path: shared.clone(),
        })
        .await;
    let serve = CoreCommand::StartServe {
        bind: "127.0.0.1".to_owned(),
        port: 0,
    };
    let (serving, started) = desktop.ok(serve).await;
    let ReplyResult::ServeStarted(started) = started else {
        panic!("expected serving to start");
    };
    assert_eq!(started.device_id, desktop_id);
    assert_eq!(started.advertised, format!("127.0.0.1:{}", started.port));
    let at = Some(format!("127.0.0.1:{}", started.port));

    let probe = CoreCommand::ProbePeer {
        device_id: desktop_id.clone(),
        address: at.clone(),
    };
    assert!(matches!(
        phone.ok(probe).await.1,
        ReplyResult::PeerProbed(ProbeOutcome::Reachable { ref address }) if Some(address) == at.as_ref()
    ));

    write(&phone.path("mine/photo.jpg"), "jpeg");
    let run = CoreCommand::StartRun {
        target: RunTarget::Pair {
            draft: ProfileDraft {
                peer_device_id: desktop_id.clone(),
                entries: vec![EntryDraft {
                    kind: RootKindView::Folder,
                    local_root: phone.path_text("mine"),
                    remote_root: shared.clone(),
                }],
                jobs: None,
                ignore: Vec::new(),
            },
        },
        dry_run: false,
        address: at.clone(),
        default_warn_size_bytes: None,
        mass_delete_min_files: 10,
        mass_delete_percent: 50,
    };
    let (session, _) = phone.ok(run).await;
    let reviewing = phone
        .run_until(session, |view| {
            matches!(view.phase, RunPhaseView::Reviewing(_))
        })
        .await;
    assert!(
        reviewing
            .iter()
            .any(|view| matches!(view.phase, RunPhaseView::Scanning))
    );
    let confirm = CoreCommand::SteerRun {
        session,
        intent: RunIntent::Confirm,
    };
    phone.ok(confirm).await;
    let finished = phone
        .run_until(session, |view| {
            matches!(view.phase, RunPhaseView::Finished(_))
        })
        .await;
    assert!(matches!(
        finished.last().map(|view| &view.phase),
        Some(RunPhaseView::Finished(summary)) if summary.applied == 1
    ));
    assert_eq!(read(&desktop.path("shared/photo.jpg")), "jpeg");

    // The first view answers where it was bound, with nothing reported.
    let first = desktop.serve_view(serving).await;
    assert!(matches!(
        first.phase,
        ServePhaseView::Listening { ref advertised } if *advertised == started.advertised
    ));
    assert!(first.lines.is_empty());

    let stop = CoreCommand::StopServe { session: serving };
    assert!(matches!(desktop.ok(stop).await.1, ReplyResult::Done));
    let last = loop {
        let snapshot = desktop.serve_snapshot(serving).await;
        if !matches!(snapshot.view.phase, ServePhaseView::Listening { .. }) {
            assert!(snapshot.last, "serving's last snapshot");
            break snapshot.view;
        }
        assert!(!snapshot.last);
    };
    assert!(matches!(last.phase, ServePhaseView::Stopped));
    // The desktop saw the phone's sessions (the probe's and the run's) and
    // which root the run was served, newest first.
    assert!(last.lines.iter().any(|line| matches!(
        &line.event,
        ServeEventView::Started { device_id, name, .. } if *device_id == phone_id && name == "phone"
    )));
    assert!(last.lines.iter().any(|line| matches!(
        &line.event,
        ServeEventView::Serving { root } if *root == shared
    )));
    assert!(
        last.lines
            .windows(2)
            .all(|pair| pair[0].at_ms >= pair[1].at_ms)
    );
    let probe = CoreCommand::ProbePeer {
        device_id: desktop_id,
        address: at,
    };
    assert!(matches!(
        phone.ok(probe).await.1,
        ReplyResult::PeerProbed(ProbeOutcome::Unreachable { .. })
    ));
}
