//! The grant check at `hello`: exact membership of the expanded root,
//! one generic refusal, and the factory - so the filesystem - never
//! reached for a root the device was not granted.

use dsync_core::{GRANTS_NEST, NOT_GRANTED, Replica, ReplicaError, resolve_grant};
use dsync_domain::ReplicaRoot;

use crate::peer::support::{Host, identity, serve, somewhere, with_deadline};

/// `hello` for `root` from a device granted only `granted`; the far
/// side's refusal text when refused.
async fn hello_refusal(server: &Host, client: &Host, root: &str) -> Option<String> {
    let serving = serve(server).await;
    let dialed = with_deadline("dial", client.dial("desktop", Some(serving.at), root))
        .await
        .unwrap();
    let hello = with_deadline("hello", dialed.replica.hello()).await;
    let _ = with_deadline("close", dialed.replica.close()).await;
    let refusal = match hello {
        Ok(_) => None,
        Err(ReplicaError::Refused(text)) => Some(text),
        Err(other) => panic!("not a refusal: {other}"),
    };
    assert_eq!(
        serving.opened(),
        usize::from(refusal.is_none()),
        "the factory runs for exactly the granted root"
    );
    refusal
}

fn hosts() -> (Host, Host) {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    let granted = server.root("granted");
    std::fs::create_dir_all(&granted).unwrap();
    server.pair(&client.identity, "phone", somewhere(), &[granted.as_path()]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    (server, client)
}

#[cfg(unix)]
#[tokio::test]
async fn ungranted_missing_and_unreadable_roots_get_the_same_refusal_untouched() {
    use crate::peer::support::dir_with_mode;

    let (server, client) = hosts();
    let existing = server.root("existing");
    std::fs::create_dir_all(&existing).unwrap();
    let missing = server.root("missing");
    let locked = server.root("locked");
    dir_with_mode(&locked, 0o000);
    let behind_lock = locked.join("inside");

    let mut refusals = Vec::new();
    for root in [&existing, &missing, &behind_lock] {
        refusals.push(hello_refusal(&server, &client, root.to_str().unwrap()).await);
    }
    dir_with_mode(&locked, 0o700);

    let expected = Some(NOT_GRANTED.to_owned());
    assert_eq!(refusals, vec![expected.clone(), expected.clone(), expected]);
    // Nothing was created where a refused root would have been opened.
    assert!(!missing.exists());

    // Positive control: the granted root, identical setup, is served.
    let granted = server.root("granted");
    assert_eq!(
        hello_refusal(&server, &client, granted.to_str().unwrap()).await,
        None
    );
}

#[tokio::test]
async fn membership_is_exact_after_expansion() {
    let (server, client) = hosts();
    let granted = server.root("granted");
    let text = granted.to_str().unwrap();
    for near_miss in [
        format!("{text}/"),
        format!("{text}/sub"),
        format!("{text}x"),
    ] {
        assert_eq!(
            hello_refusal(&server, &client, &near_miss).await.as_deref(),
            Some(NOT_GRANTED),
            "{near_miss}"
        );
    }
    // `~` expands against the serving host's home (the temp dir here),
    // the same expansion the factory uses: `~/granted` is the grant.
    assert_eq!(hello_refusal(&server, &client, "~/granted").await, None);
    assert_eq!(hello_refusal(&server, &client, text).await, None);
}

#[tokio::test]
async fn a_granted_root_that_does_not_exist_yet_is_reported_missing_and_created() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    let fresh = server.root("fresh");
    server.pair(&client.identity, "phone", somewhere(), &[fresh.as_path()]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;

    let dialed = with_deadline(
        "dial",
        client.dial("desktop", Some(serving.at), fresh.to_str().unwrap()),
    )
    .await
    .unwrap();
    let info = with_deadline("hello", dialed.replica.hello())
        .await
        .unwrap();
    assert!(
        matches!(info.root, ReplicaRoot::Missing { .. }),
        "{:?}",
        info.root
    );
    with_deadline("create", dialed.replica.create_root())
        .await
        .unwrap();
    with_deadline("close", dialed.replica.close())
        .await
        .unwrap();
    assert!(fresh.is_dir());
}

/// A single file may be granted: the grant check is the same exact match.
#[tokio::test]
async fn a_granted_file_is_served_and_a_file_inside_a_granted_folder_is_not() {
    let (server, client) = hosts();
    let inside = server.root("granted").join("inside.txt");
    std::fs::write(&inside, "in a granted folder, not granted itself").unwrap();
    let file = server.root("notes.txt");
    std::fs::write(&file, "granted on its own").unwrap();
    server
        .store()
        .update(|devices| {
            devices.grant(
                &client.identity.device_id(),
                file.to_str().unwrap().to_owned(),
                resolve_grant,
            )
        })
        .unwrap();

    assert_eq!(
        hello_refusal(&server, &client, inside.to_str().unwrap())
            .await
            .as_deref(),
        Some(NOT_GRANTED)
    );
    assert_eq!(
        hello_refusal(&server, &client, file.to_str().unwrap()).await,
        None
    );
}

/// Grants that nest only as the host resolves them now - one replaced by
/// a link into another after both were granted - refuse every hello from
/// that device, after the grant check.
#[cfg(unix)]
#[tokio::test]
async fn grants_made_to_nest_after_granting_refuse_the_hello() {
    let (server, client) = hosts();
    let granted = server.root("granted");
    let other = server.root("other");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::create_dir_all(granted.join("inner")).unwrap();
    server
        .store()
        .update(|devices| {
            devices.grant(
                &client.identity.device_id(),
                other.to_str().unwrap().to_owned(),
                resolve_grant,
            )
        })
        .unwrap();

    // Positive control: the same grants, nothing moved, are served.
    for root in [&granted, &other] {
        assert_eq!(
            hello_refusal(&server, &client, root.to_str().unwrap()).await,
            None
        );
    }

    std::fs::remove_dir(&other).unwrap();
    std::os::unix::fs::symlink(granted.join("inner"), &other).unwrap();

    for root in [&granted, &other] {
        assert_eq!(
            hello_refusal(&server, &client, root.to_str().unwrap())
                .await
                .as_deref(),
            Some(GRANTS_NEST),
            "{}",
            root.display()
        );
    }
    // A root never granted still gets exactly the generic refusal.
    assert_eq!(
        hello_refusal(&server, &client, server.root("elsewhere").to_str().unwrap())
            .await
            .as_deref(),
        Some(NOT_GRANTED)
    );
}
