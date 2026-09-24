//! One-shot commands: each answered from a real core flow on the head's
//! temp state and config directories.

use std::time::SystemTime;

use dsync_core::{DeviceIdentity, PairedDevice, PairedDeviceStore, ProfileStore, StateDir};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    DIR_LEAF, HostFacts, Location, Platform, Profile, ProfileName, ReplicaLocation,
};
use hub::signals::{CoreCommand, ProfileDraft, ReplyResult};
use hub::views::{DeviceView, EntryKindView, ProfileEntry};
use hub::{Core, Outbox};

use crate::support::{Head, write};

/// Pairs a fresh identity as `name` straight through the store, as a
/// finished pairing would have: returns its device id.
fn seed_device(head: &Head, name: &str) -> String {
    let identity = DeviceIdentity::generate(name, SystemTime::now())
        .unwrap_or_else(|error| panic!("identity: {error}"));
    let device = PairedDevice::new(
        identity.certificate().clone(),
        dsync_domain::PeerName::parse(name).unwrap_or_else(|error| panic!("{error}")),
        PeerAddress::new("192.168.1.5", 28771).unwrap_or_else(|error| panic!("{error}")),
        SystemTime::now(),
    );
    PairedDeviceStore::new(&StateDir::new(head.state()))
        .update(|devices| devices.add(device))
        .unwrap_or_else(|error| panic!("pair: {error}"));
    identity.device_id().to_string()
}

fn devices(result: ReplyResult) -> Vec<DeviceView> {
    match result {
        ReplyResult::Devices(devices) => devices,
        _ => panic!("expected the device list"),
    }
}

#[tokio::test]
async fn a_command_before_init_is_refused_and_init_resolves_the_support_dir() {
    let dir = tempfile::tempdir().unwrap_or_else(|error| panic!("{error}"));
    let home = dir.path().to_string_lossy().into_owned();
    let (out, _outgoing) = Outbox::channel();
    let core = Core::new(
        HostFacts::new(Platform::HOST, Some(home.clone()), Vec::new(), home),
        out,
    );
    let refused = core.handle(1, CoreCommand::ShowIdentity).await;
    assert_eq!(refused.id, 1);
    assert!(matches!(refused.result, ReplyResult::Failed { .. }));

    let support = dir.path().join("support").to_string_lossy().into_owned();
    let init = CoreCommand::Init {
        support_dir: Some(support),
        device_name: "phone".to_owned(),
    };
    assert!(matches!(
        core.handle(2, init).await.result,
        ReplyResult::Done
    ));
    let shown = core.handle(3, CoreCommand::ShowIdentity).await;
    assert!(matches!(shown.result, ReplyResult::Identity(_)));
    // The identity lives under the support dir plus the Rust leaf.
    assert!(
        dir.path()
            .join("support")
            .join(DIR_LEAF)
            .join("identity.crt")
            .exists()
    );
}

#[tokio::test]
async fn the_identity_is_created_once_and_renewal_keeps_its_id() {
    let mut head = Head::new("studio").await;
    let ReplyResult::Identity(shown) = head.ok(CoreCommand::ShowIdentity).await.1 else {
        panic!("expected the identity");
    };
    assert_eq!(shown.common_name.as_deref(), Some("studio"));
    assert!(
        shown.expiry_note.is_none(),
        "a fresh certificate is not due"
    );
    let ReplyResult::Identity(again) = head.ok(CoreCommand::ShowIdentity).await.1 else {
        panic!("expected the identity");
    };
    assert_eq!(again.device_id, shown.device_id);

    let renew = CoreCommand::RenewIdentity {
        common_name: Some("studio-2".to_owned()),
    };
    let ReplyResult::Identity(renewed) = head.ok(renew).await.1 else {
        panic!("expected the identity");
    };
    assert_eq!(renewed.device_id, shown.device_id);
    assert_eq!(renewed.common_name.as_deref(), Some("studio-2"));
}

#[tokio::test]
async fn devices_are_listed_renamed_granted_withdrawn_and_revoked() {
    let mut head = Head::new("studio").await;
    assert!(devices(head.ok(CoreCommand::ListDevices).await.1).is_empty());
    let id = seed_device(&head, "phone");

    let listed = devices(head.ok(CoreCommand::ListDevices).await.1);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].device_id, id);
    assert_eq!(listed[0].address, "192.168.1.5:28771");
    assert!(listed[0].granted_roots.is_empty());

    let renamed = devices(
        head.ok(CoreCommand::RenameDevice {
            device_id: id.clone(),
            name: "pocket".to_owned(),
        })
        .await
        .1,
    );
    assert_eq!(renamed[0].name, "pocket");
    let blank = head
        .failure(CoreCommand::RenameDevice {
            device_id: id.clone(),
            name: "  ".to_owned(),
        })
        .await;
    assert!(blank.contains("empty or blank"), "{blank}");

    // `~` is expanded against this host's home before it is stored.
    let granted = devices(
        head.ok(CoreCommand::GrantRoot {
            device_id: id.clone(),
            path: "~/notes".to_owned(),
        })
        .await
        .1,
    );
    let expanded = head.path_text("notes");
    assert_eq!(granted[0].granted_roots, std::slice::from_ref(&expanded));

    let withdrawn = devices(
        head.ok(CoreCommand::WithdrawGrant {
            device_id: id.clone(),
            root: expanded,
        })
        .await
        .1,
    );
    assert!(withdrawn[0].granted_roots.is_empty());

    let revoked = devices(
        head.ok(CoreCommand::RevokeDevice {
            device_id: id.clone(),
        })
        .await
        .1,
    );
    assert!(revoked.is_empty());
    let gone = head
        .failure(CoreCommand::RevokeDevice { device_id: id })
        .await;
    assert!(!gone.is_empty());
    let garbled = head
        .failure(CoreCommand::RevokeDevice {
            device_id: "not an id".to_owned(),
        })
        .await;
    assert!(!garbled.is_empty());
}

fn draft(head: &Head, peer: &str, local_leaf: &str) -> ProfileDraft {
    ProfileDraft {
        local_root: head.path_text(local_leaf),
        peer_device_id: peer.to_owned(),
        remote_root: "/sdcard/notes".to_owned(),
        jobs: Some(2),
        ignore: vec!["**/.git".to_owned()],
    }
}

fn profiles(result: ReplyResult) -> Vec<ProfileEntry> {
    match result {
        ReplyResult::Profiles(profiles) => profiles,
        _ => panic!("expected the profile list"),
    }
}

#[tokio::test]
async fn a_saved_profile_lists_with_its_peer_its_folder_check_and_its_id() {
    let mut head = Head::new("studio").await;
    let peer = seed_device(&head, "phone");
    std::fs::create_dir_all(head.path("notes")).unwrap_or_else(|error| panic!("{error}"));
    let save = CoreCommand::SaveProfile {
        name: "Notes".to_owned(),
        draft: draft(&head, &peer, "notes"),
    };
    let saved = profiles(head.ok(save).await.1);
    let [ProfileEntry::Head(notes)] = &saved[..] else {
        panic!("expected one head-shaped profile");
    };
    assert_eq!(notes.name, "Notes");
    assert_eq!(notes.peer_device_id, peer);
    assert_eq!(notes.peer_name.as_deref(), Some("phone"));
    assert_eq!(notes.remote_root, "/sdcard/notes");
    assert_eq!(notes.jobs, Some(2));
    assert_eq!(notes.ignore, ["**/.git"]);
    assert_eq!(notes.local_root_refusal, None);
    assert!(!notes.last_run_unfinished);
    assert_eq!(notes.profile_id.len(), 32);

    // A second profile over a folder that is gone lists as refused.
    let save = CoreCommand::SaveProfile {
        name: "Gone".to_owned(),
        draft: draft(&head, &peer, "gone"),
    };
    let listed = profiles(head.ok(save).await.1);
    let refused = listed.iter().find_map(|entry| match entry {
        ProfileEntry::Head(view) if view.name == "Gone" => Some(view),
        _ => None,
    });
    assert!(refused.is_some_and(|view| view.local_root_refusal.is_some()));

    let renamed = profiles(
        head.ok(CoreCommand::RenameProfile {
            from: "Gone".to_owned(),
            to: "Old".to_owned(),
        })
        .await
        .1,
    );
    assert!(
        renamed
            .iter()
            .any(|entry| matches!(entry, ProfileEntry::Head(view) if view.name == "Old"))
    );
    let left = profiles(
        head.ok(CoreCommand::DeleteProfile {
            name: "Old".to_owned(),
        })
        .await
        .1,
    );
    assert_eq!(left.len(), 1);

    // A draft naming a device that is not paired is refused.
    let unpaired = head
        .failure(CoreCommand::SaveProfile {
            name: "X".to_owned(),
            draft: draft(&head, &seed_device_elsewhere(), "notes"),
        })
        .await;
    assert!(unpaired.contains("paired"), "{unpaired}");
}

fn seed_device_elsewhere() -> String {
    DeviceIdentity::generate("stranger", SystemTime::now())
        .unwrap_or_else(|error| panic!("{error}"))
        .device_id()
        .to_string()
}

#[tokio::test]
async fn a_profile_of_another_shape_and_an_unreadable_one_are_listed_as_such() {
    let mut head = Head::new("studio").await;
    let config = head.path("support").join(DIR_LEAF);
    let store = ProfileStore::new(&config);
    let local = |leaf: &str| {
        ReplicaLocation::new(
            Location::parse(&head.path_text(leaf), Platform::HOST)
                .unwrap_or_else(|error| panic!("{error}")),
            None,
        )
        .unwrap_or_else(|error| panic!("{error}"))
    };
    let name = ProfileName::parse("pair").unwrap_or_else(|error| panic!("{error}"));
    store
        .save(&name, &Profile::new(local("a"), local("b")))
        .unwrap_or_else(|error| panic!("{error}"));
    write(&config.join("profiles").join("broken.toml"), "[nope");
    let listed = profiles(head.ok(CoreCommand::ListProfiles).await.1);
    assert!(listed.iter().any(|entry| matches!(
        entry,
        ProfileEntry::Other { name, profile_id: Some(_), .. } if name == "pair"
    )));
    assert!(listed.iter().any(|entry| matches!(
        entry,
        ProfileEntry::Unreadable { name, .. } if name == "broken"
    )));
}

#[tokio::test]
async fn a_folder_is_checked_by_writing_in_it() {
    let mut head = Head::new("studio").await;
    std::fs::create_dir_all(head.path("ok")).unwrap_or_else(|error| panic!("{error}"));
    let usable = head
        .ok(CoreCommand::CheckFolder {
            path: head.path_text("ok"),
        })
        .await
        .1;
    assert!(matches!(
        usable,
        ReplyResult::FolderChecked { refusal: None }
    ));
    let missing = head
        .ok(CoreCommand::CheckFolder {
            path: head.path_text("missing"),
        })
        .await
        .1;
    assert!(matches!(
        missing,
        ReplyResult::FolderChecked { refusal: Some(ref why) } if why.contains("missing")
    ));
}

#[tokio::test]
async fn the_filter_preview_counts_what_a_rule_removes_and_lists_a_folder() {
    let mut head = Head::new("studio").await;
    write(&head.path("tree/keep.txt"), "12345");
    write(&head.path("tree/.git/HEAD"), "ref");
    let preview = CoreCommand::PreviewFilters {
        root: head.path_text("tree"),
        ignore: vec![".git".to_owned()],
    };
    let ReplyResult::FilterPreview(preview) = head.ok(preview).await.1 else {
        panic!("expected the preview");
    };
    let root = &preview.folders[0];
    assert_eq!((root.path.as_deref(), root.depth), (None, 0));
    assert_eq!((root.included_files, root.included_bytes), (1, 5));
    assert_eq!(root.excluded_files, 1);
    assert_eq!(preview.excluded_by_rule[0].pattern, ".git");
    assert!(
        preview
            .folders
            .iter()
            .any(|folder| folder.path.as_deref() == Some(".git") && folder.depth == 1)
    );

    let listing = CoreCommand::ListFilterFolder {
        root: head.path_text("tree"),
        folder: None,
        ignore: vec![".git".to_owned()],
    };
    let ReplyResult::FilterFolder(rows) = head.ok(listing).await.1 else {
        panic!("expected the rows");
    };
    let git = rows.iter().find(|row| row.name == ".git");
    assert!(git.is_some_and(|row| !row.syncs && row.excluded_by.as_deref() == Some(".git")));
    let keep = rows.iter().find(|row| row.name == "keep.txt");
    assert!(
        keep.is_some_and(|row| row.syncs && matches!(row.kind, EntryKindView::File { size: 5 }))
    );

    let bad = head
        .failure(CoreCommand::PreviewFilters {
            root: head.path_text("tree"),
            ignore: vec!["[".to_owned()],
        })
        .await;
    assert!(!bad.is_empty());
}

#[tokio::test]
async fn the_scan_probe_climbs_every_layer_once_per_pass() {
    let mut head = Head::new("studio").await;
    write(&head.path("tree/a.txt"), "a");
    write(&head.path("tree/sub/b.txt"), "bb");
    let probe = CoreCommand::ProbeScan {
        root: head.path_text("tree"),
        ignore: Vec::new(),
        passes: 2,
    };
    let ReplyResult::ScanProbe(report) = head.ok(probe).await.1 else {
        panic!("expected the probe report");
    };
    assert_eq!(report.passes.len(), 2);
    assert!(!report.passes[0].layers.is_empty());
    assert!(report.passes[0].layers.iter().all(|layer| layer.files == 2));
    assert!(!report.report.is_empty());
}

#[tokio::test]
async fn archives_list_empty_on_a_host_that_never_synced() {
    let mut head = Head::new("studio").await;
    let ReplyResult::Archives(archives) = head.ok(CoreCommand::ListArchives).await.1 else {
        panic!("expected the archives");
    };
    assert!(archives.is_empty());
}

#[tokio::test]
async fn serve_addresses_list_this_machine_s_interfaces() {
    let mut head = Head::new("studio").await;
    let ReplyResult::Addresses(addresses) = head.ok(CoreCommand::ServeAddresses).await.1 else {
        panic!("expected the addresses");
    };
    // Loopback at least, never offered as the one to advertise.
    assert!(!addresses.interfaces.is_empty());
    assert_ne!(addresses.preferred.as_deref(), Some("127.0.0.1"));
}
