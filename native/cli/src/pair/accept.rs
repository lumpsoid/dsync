//! `dsync pair accept <payload>` (SPEC §4.4): the other side of `pair
//! show`. A refusal names its reason: whoever reads this is the operator
//! pairing two devices they hold, not a stranger probing, so "wrong
//! token", "declined" and "stale payload" each point at a different fix.

use std::time::SystemTime;

use dsync_core::{DeviceIdentityStore, EnrolError, EnrolmentDialer, PairedDeviceStore};
use dsync_domain::{PairingPayload, Tuning};

use super::{peer_name, state_dir};
use crate::args::PairAcceptArgs;
use crate::failure::Failure;
use crate::host::Host;

pub async fn accept(args: PairAcceptArgs, host: &Host) -> Result<u8, Failure> {
    let name = peer_name(
        &args.name,
        "dsync pair accept needs --name: this host's own label for the device being paired.",
    )?;
    let state = state_dir(&args.state, host)?;
    let payload = PairingPayload::decode(args.payload.trim())
        .map_err(|error| Failure::usage(format!("dsync pair accept: {error}")))?;
    let identity = DeviceIdentityStore::new(&state)
        .load_or_create(&Host::name(), SystemTime::now())
        .map_err(|error| Failure::Fatal(format!("dsync pair accept: {error}")))?;
    // Before connecting: the far side asks its operator to compare this id
    // while the connection is open, so it has to be on screen by then.
    eprintln!(
        "dsync pair accept: this device is {}. The device that showed the payload will ask \
         whoever is there to confirm that id before it records the pairing (SPEC §4.4).",
        identity.device_id()
    );
    let dialer = EnrolmentDialer::new(identity, PairedDeviceStore::new(&state), Tuning::DEFAULT);
    let paired = dialer.enrol(&payload, name).await.map_err(enrol_failure)?;
    println!("paired: \"{}\" ({})", paired.name(), paired.device_id());
    Ok(0)
}

fn enrol_failure(error: EnrolError) -> Failure {
    let message = match &error {
        EnrolError::Denied(denial) => format!("enrolment refused: {denial}"),
        EnrolError::Impostor { .. } | EnrolError::PeerCertificate(_) | EnrolError::Tls { .. } => {
            format!(
                "{error}. Either the payload is stale, or it names a different device than the \
                 one that answered — get a fresh payload from `dsync pair show`."
            )
        }
        _ => error.to_string(),
    };
    Failure::Fatal(format!("dsync pair accept: {message}"))
}
