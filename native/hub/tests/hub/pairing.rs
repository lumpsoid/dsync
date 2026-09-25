//! Two heads meeting over loopback: one shows a pairing window, the other
//! redeems it, the first confirms; then the first serves, the second
//! probes it and runs against it - every step a hub command.

use hub::signals::{
    CoreCommand, EnrolmentUpdateBody, KeptAction, ProfileDraft, ReplyResult, RunDecision,
    RunTarget, RunUpdateBody, ServeUpdateBody,
};
use hub::views::{EnrolmentEndView, PairCodeView, ProbeOutcome, RunEndView, SideView};

use crate::support::{Head, read, write};

fn show(name: &str) -> CoreCommand {
    CoreCommand::ShowPairing {
        name: name.to_owned(),
        bind: "127.0.0.1".to_owned(),
        advertise: None,
        service_port: 28771,
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
    let ReplyResult::PairingShown(shown) = shown else {
        panic!("expected the payload");
    };
    let phone_id = device_id(phone).await;
    let ReplyResult::PairCode(PairCodeView::Read {
        device_id: Some(read_id),
        address,
        ..
    }) = phone
        .ok(CoreCommand::ReadPairCode {
            text: format!("  {}\n", shown.payload),
        })
        .await
        .1
    else {
        panic!("the payload should read");
    };
    assert_eq!(read_id, shown.device_id);
    assert_eq!(address, "127.0.0.1:28771");

    let accept = CoreCommand::AcceptPairing {
        code: shown.payload.clone(),
        name: "desktop".to_owned(),
    };
    let confirming = async {
        let EnrolmentUpdateBody::Awaiting {
            device_id, name, ..
        } = desktop.enrolment_update(session).await
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
        desktop.enrolment_update(session).await
    };
    let (accepted, ended) = tokio::join!(phone.ok(accept), confirming);
    let ReplyResult::Device(paired) = accepted.1 else {
        panic!("expected the paired device");
    };
    assert_eq!(paired.name, "desktop");
    assert_eq!(paired.device_id, shown.device_id);
    assert!(matches!(
        ended,
        EnrolmentUpdateBody::Ended(EnrolmentEndView::Enrolled(ref device)) if device.device_id == phone_id
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
async fn a_pairing_window_closes_when_cancelled_and_confirming_it_then_fails() {
    let mut desktop = Head::new("desktop").await;
    let (session, _) = desktop.ok(show("phone")).await;
    let cancel = CoreCommand::CancelPairing { session };
    assert!(matches!(desktop.ok(cancel).await.1, ReplyResult::Done));
    assert!(matches!(
        desktop.enrolment_update(session).await,
        EnrolmentUpdateBody::Ended(EnrolmentEndView::Cancelled)
    ));
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
    let (session, shown) = desktop.ok(show("phone")).await;
    let ReplyResult::PairingShown(shown) = shown else {
        panic!("expected the payload");
    };
    let accept = CoreCommand::AcceptPairing {
        code: shown.payload,
        name: "desktop".to_owned(),
    };
    let declining = async {
        let awaiting = desktop.enrolment_update(session).await;
        assert!(matches!(awaiting, EnrolmentUpdateBody::Awaiting { .. }));
        let decline = CoreCommand::ConfirmPairing {
            session,
            accept: false,
        };
        desktop.ok(decline).await;
        desktop.enrolment_update(session).await
    };
    let (refused, ended) = tokio::join!(phone.ask(accept), declining);
    assert!(matches!(refused.1, ReplyResult::Failed { .. }));
    assert!(matches!(
        ended,
        EnrolmentUpdateBody::Ended(EnrolmentEndView::Declined { .. })
    ));
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
                local_root: phone.path_text("mine"),
                peer_device_id: desktop_id.clone(),
                remote_root: shared.clone(),
                jobs: None,
                ignore: Vec::new(),
            },
        },
        dry_run: false,
        address: at.clone(),
    };
    let (session, _) = phone.ok(run).await;
    let planned = phone
        .run_until(session, |update| {
            matches!(update, RunUpdateBody::Plan { .. })
        })
        .await;
    assert!(matches!(
        &planned[0],
        RunUpdateBody::Connected { peers } if peers.len() == 1
            && matches!(peers[0].side, SideView::B)
            && peers[0].device_id == desktop_id
            && peers[0].notes.is_empty()
    ));
    let decide = CoreCommand::DecideRun {
        session,
        decision: RunDecision {
            keep: vec![KeptAction {
                index: 0,
                reversed: false,
            }],
            resolve: Vec::new(),
        },
    };
    phone.ok(decide).await;
    let ended = phone
        .run_until(session, |update| matches!(update, RunUpdateBody::Ended(_)))
        .await;
    assert!(matches!(
        ended.last(),
        Some(RunUpdateBody::Ended(RunEndView::Ran { summary: Some(summary), errored: false, .. }))
            if summary.applied == 1
    ));
    assert_eq!(read(&desktop.path("shared/photo.jpg")), "jpeg");

    let stop = CoreCommand::StopServe { session: serving };
    assert!(matches!(desktop.ok(stop).await.1, ReplyResult::Done));
    let mut story = Vec::new();
    loop {
        let update = desktop.serve_update(serving).await;
        if let ServeUpdateBody::Stopped { failure } = update {
            assert_eq!(failure, None);
            break;
        }
        story.push(update);
    }
    // The desktop saw the phone's sessions (the probe's and the run's) and
    // which root the run was served.
    assert!(story.iter().any(|update| matches!(
        update,
        ServeUpdateBody::Started { device_id, name, .. } if *device_id == phone_id && name == "phone"
    )));
    assert!(story.iter().any(|update| matches!(
        update,
        ServeUpdateBody::Serving { root } if *root == shared
    )));
    let probe = CoreCommand::ProbePeer {
        device_id: desktop_id,
        address: at,
    };
    assert!(matches!(
        phone.ok(probe).await.1,
        ReplyResult::PeerProbed(ProbeOutcome::Unreachable { .. })
    ));
}
