//! One-shot commands: each answered from a real core flow on the head's
//! temp state and config directories.

use std::time::SystemTime;

use dsync_core::{
    DeviceIdentity, MarkerPair, MarkerRecord, PairedDevice, PairedDeviceStore, ProfileStore,
    RunMarker, StateDir,
};
use dsync_domain::host_port::PeerAddress;
use dsync_domain::{
    DIR_LEAF, EntryId, HostFacts, Location, Platform, ProfileName, ReplicaLocation,
};
use hub::signals::{CoreCommand, EntryDraft, ProfileDraft, ReplyResult};
use hub::views::{
    DeviceView, EntryKindView, LastRunView, ProfileEntry, ProfileView, RootKindView, UnsavedRunView,
};
use hub::{Core, Outbox};

use crate::support::{Head, one_entry, write};

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
    let ReplyResult::Initialised(dirs) = core.handle(2, init).await.result else {
        panic!("expected the core's directories");
    };
    // Both under the support dir plus the Rust leaf: the head puts its
    // settings.json in the state dir, so it never writes Dart-era state.
    let leaf = dir.path().join("support").join(DIR_LEAF);
    assert_eq!(dirs.state_dir, leaf.to_string_lossy());
    assert_eq!(dirs.profiles_dir, leaf.join("profiles").to_string_lossy());
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

#[tokio::test]
async fn a_device_s_grants_are_listed_once_each_in_order() {
    let mut head = Head::new("studio").await;
    let id = seed_device(&head, "phone");
    let (a, b) = (head.path_text("a"), head.path_text("b"));

    for path in [&b, &a, &b] {
        head.ok(CoreCommand::GrantRoot {
            device_id: id.clone(),
            path: path.clone(),
        })
        .await;
    }

    let listed = devices(head.ok(CoreCommand::ListDevices).await.1);
    assert_eq!(listed[0].granted_roots, [a, b]);
}

/// `leaf` created as a folder under the head's temp dir, as text: grants
/// are judged as this host resolves them, so the folders are real.
fn folder(head: &Head, leaf: &str) -> String {
    std::fs::create_dir_all(head.path(leaf)).unwrap_or_else(|error| panic!("mkdir: {error}"));
    head.path_text(leaf)
}

fn grant(id: &str, path: &str) -> CoreCommand {
    CoreCommand::GrantRoot {
        device_id: id.to_owned(),
        path: path.to_owned(),
    }
}

/// The paired-devices file as it stands on disk.
fn paired_bytes(head: &Head) -> Vec<u8> {
    let store = PairedDeviceStore::new(&StateDir::new(head.state()));
    std::fs::read(store.path()).unwrap_or_else(|error| panic!("read: {error}"))
}

#[tokio::test]
async fn a_folder_inside_a_granted_folder_is_refused_naming_the_grant() {
    let mut head = Head::new("studio").await;
    let id = seed_device(&head, "phone");
    let outer = folder(&head, "a/b");
    let inner = folder(&head, "a/b/c");
    head.ok(grant(&id, &outer)).await;
    let before = paired_bytes(&head);

    let refused = head.failure(grant(&id, &inner)).await;
    assert!(refused.contains("grants never nest"), "{refused}");
    assert!(refused.contains(&format!("overlaps {outer}")), "{refused}");
    assert_eq!(paired_bytes(&head), before);

    // Positive controls: the identical path again is a no-op, and a
    // sibling that only shares a prefix of characters is granted.
    let again = devices(head.ok(grant(&id, &outer)).await.1);
    assert_eq!(again[0].granted_roots, std::slice::from_ref(&outer));
    assert_eq!(paired_bytes(&head), before);
    let sibling = folder(&head, "a/bc");
    let granted = devices(head.ok(grant(&id, &sibling)).await.1);
    assert_eq!(granted[0].granted_roots, [outer, sibling]);
}

#[tokio::test]
async fn a_folder_holding_a_granted_file_or_folder_is_refused() {
    let mut head = Head::new("studio").await;
    let id = seed_device(&head, "phone");
    let file = head.path("f/notes.txt");
    write(&file, "notes");
    let file = file.to_string_lossy().into_owned();
    let inner = folder(&head, "d/inner");
    head.ok(grant(&id, &file)).await;
    head.ok(grant(&id, &inner)).await;
    let before = paired_bytes(&head);

    let over_file = head.failure(grant(&id, &head.path_text("f"))).await;
    assert!(
        over_file.contains(&format!("overlaps {file}")),
        "{over_file}"
    );
    let over_folder = head.failure(grant(&id, &head.path_text("d"))).await;
    assert!(
        over_folder.contains(&format!("overlaps {inner}")),
        "{over_folder}"
    );
    assert_eq!(paired_bytes(&head), before);

    // Positive control: a folder beside them both is granted.
    let beside = folder(&head, "e");
    let granted = devices(head.ok(grant(&id, &beside)).await.1);
    assert_eq!(granted[0].granted_roots.len(), 3);
    assert!(granted[0].granted_roots.contains(&beside));
}

#[cfg(unix)]
#[tokio::test]
async fn a_link_resolving_to_a_granted_folder_is_refused() {
    let mut head = Head::new("studio").await;
    let id = seed_device(&head, "phone");
    let real = folder(&head, "real");
    let link = head.path_text("link");
    std::os::unix::fs::symlink(&real, &link).unwrap_or_else(|error| panic!("link: {error}"));
    head.ok(grant(&id, &real)).await;
    let before = paired_bytes(&head);

    let refused = head.failure(grant(&id, &link)).await;
    assert!(refused.contains(&format!("overlaps {real}")), "{refused}");
    assert_eq!(paired_bytes(&head), before);

    // Positive control: the real folder's own spelling again is a no-op.
    let again = devices(head.ok(grant(&id, &real)).await.1);
    assert_eq!(again[0].granted_roots, [real]);
}

#[tokio::test]
async fn a_device_s_address_and_verification_are_set_by_hand() {
    let mut head = Head::new("studio").await;
    let id = seed_device(&head, "phone");

    let moved = devices(
        head.ok(CoreCommand::SetDeviceAddress {
            device_id: id.clone(),
            address: "10.0.0.7".to_owned(),
        })
        .await
        .1,
    );
    assert_eq!(moved[0].address, "10.0.0.7:28771");
    let with_port = devices(
        head.ok(CoreCommand::SetDeviceAddress {
            device_id: id.clone(),
            address: "[fe80::1]:4000".to_owned(),
        })
        .await
        .1,
    );
    assert_eq!(with_port[0].address, "[fe80::1]:4000");
    let garbled = head
        .failure(CoreCommand::SetDeviceAddress {
            device_id: id.clone(),
            address: "host:notaport".to_owned(),
        })
        .await;
    assert!(!garbled.is_empty());
    let unpaired = head
        .failure(CoreCommand::SetDeviceAddress {
            device_id: seed_unpaired_id(),
            address: "10.0.0.7".to_owned(),
        })
        .await;
    assert!(unpaired.contains("no paired device"), "{unpaired}");

    assert!(moved[0].verified_at_ms.is_none());
    let verified = devices(
        head.ok(CoreCommand::VerifyDevice {
            device_id: id.clone(),
        })
        .await
        .1,
    );
    assert!(verified[0].verified_at_ms.is_some());
    let cleared = devices(
        head.ok(CoreCommand::ClearVerification { device_id: id })
            .await
            .1,
    );
    assert!(cleared[0].verified_at_ms.is_none());
}

/// A well-formed device id no store holds.
fn seed_unpaired_id() -> String {
    DeviceIdentity::generate("stranger", SystemTime::now())
        .unwrap_or_else(|error| panic!("identity: {error}"))
        .device_id()
        .to_string()
}

#[tokio::test]
async fn an_ignore_pattern_is_checked_on_its_own() {
    let mut head = Head::new("studio").await;
    let (_, good) = head
        .ok(CoreCommand::CheckIgnorePattern {
            pattern: "**/*.tmp".to_owned(),
        })
        .await;
    assert!(matches!(good, ReplyResult::Done));
    let bad = head
        .failure(CoreCommand::CheckIgnorePattern {
            pattern: "[unclosed".to_owned(),
        })
        .await;
    assert!(!bad.is_empty());
}

#[tokio::test]
async fn the_heads_errors_are_noted_and_read_back_under_the_build() {
    let mut head = Head::new("studio").await;
    let (_, noted) = head
        .ok(CoreCommand::NoteDiagnostic {
            message: "dart error: Bad state\n#0 main".to_owned(),
        })
        .await;
    assert!(matches!(noted, ReplyResult::Done));
    let (_, read) = head.ok(CoreCommand::ReadDiagnostics).await;
    let ReplyResult::Diagnostics { text } = read else {
        panic!("expected the diagnostics");
    };
    let mut lines = text.lines();
    let build = lines.next().unwrap_or_default();
    assert!(
        build.starts_with("dsync ") && build.contains(" on "),
        "{text}"
    );
    assert!(text.contains("Z core started: dsync "), "{text}");
    assert!(
        text.contains("Z dart error: Bad state\n  #0 main"),
        "{text}"
    );
}

fn draft(head: &Head, peer: &str, local_leaf: &str) -> ProfileDraft {
    entries_draft(
        peer,
        vec![entry(
            RootKindView::Folder,
            &head.path_text(local_leaf),
            "/sdcard/notes",
        )],
    )
}

fn entries_draft(peer: &str, entries: Vec<EntryDraft>) -> ProfileDraft {
    ProfileDraft {
        peer_device_id: peer.to_owned(),
        entries,
        jobs: Some(2),
        ignore: vec!["**/.git".to_owned()],
    }
}

fn entry(kind: RootKindView, local_root: &str, remote_root: &str) -> EntryDraft {
    EntryDraft {
        kind,
        local_root: local_root.to_owned(),
        remote_root: remote_root.to_owned(),
    }
}

/// The one head-shaped profile called `name` in `listed`.
fn head_profile<'a>(listed: &'a [ProfileEntry], name: &str) -> &'a ProfileView {
    listed
        .iter()
        .find_map(|entry| match entry {
            ProfileEntry::Head(view) if view.name == name => Some(view),
            _ => None,
        })
        .unwrap_or_else(|| panic!("expected a head-shaped profile {name}"))
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
    assert_eq!(notes.jobs, Some(2));
    assert_eq!(notes.ignore, ["**/.git"]);
    assert_eq!(notes.last_run, LastRunView::Settled);
    let [only] = &notes.entries[..] else {
        panic!("expected one entry");
    };
    assert_eq!(only.kind, RootKindView::Folder);
    assert_eq!(only.local_root, head.path_text("notes"));
    assert_eq!(only.remote_root, "/sdcard/notes");
    assert_eq!(only.local_root_refusal, None);
    assert_eq!(only.entry_id.len(), 32);

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
    assert!(refused.is_some_and(|view| view.entries[0].local_root_refusal.is_some()));

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
        .save(&name, &one_entry(local("a"), local("b")))
        .unwrap_or_else(|error| panic!("{error}"));
    write(&config.join("profiles").join("broken.toml"), "[nope");
    let listed = profiles(head.ok(CoreCommand::ListProfiles).await.1);
    assert!(listed.iter().any(|entry| matches!(
        entry,
        ProfileEntry::Other { name, entries } if name == "pair"
            && entries.len() == 1
            && entries[0].a == head.path_text("a")
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
            kind: RootKindView::Folder,
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
            kind: RootKindView::Folder,
        })
        .await
        .1;
    assert!(matches!(
        missing,
        ReplyResult::FolderChecked { refusal: Some(ref why) } if why.contains("missing")
    ));
}

#[tokio::test]
async fn a_file_is_checked_by_writing_beside_it() {
    let mut head = Head::new("studio").await;
    write(&head.path("ok/notes.md"), "x");
    let check = |path: String| CoreCommand::CheckFolder {
        path,
        kind: RootKindView::File,
    };
    let usable = head.ok(check(head.path_text("ok/notes.md"))).await.1;
    assert!(matches!(
        usable,
        ReplyResult::FolderChecked { refusal: None }
    ));
    let missing = head.ok(check(head.path_text("gone/notes.md"))).await.1;
    assert!(matches!(
        missing,
        ReplyResult::FolderChecked { refusal: Some(ref why) } if why.contains("gone")
    ));
    // The same folder as a file root is the wrong kind.
    let folder = head.ok(check(head.path_text("ok"))).await.1;
    assert!(matches!(
        folder,
        ReplyResult::FolderChecked { refusal: Some(_) }
    ));
}

#[tokio::test]
async fn saving_nested_entries_is_refused_naming_both() {
    let mut head = Head::new("studio").await;
    let peer = seed_device(&head, "phone");
    let nested = entries_draft(
        &peer,
        vec![
            entry(RootKindView::Folder, &head.path_text("notes"), "/sdcard/a"),
            entry(
                RootKindView::Folder,
                &head.path_text("notes/sub"),
                "/sdcard/b",
            ),
        ],
    );
    let refused = head
        .failure(CoreCommand::SaveProfile {
            name: "Nested".to_owned(),
            draft: nested,
        })
        .await;
    assert!(refused.contains("Nested"), "{refused}");
    assert!(refused.contains("entries[0].a"), "{refused}");
    assert!(refused.contains("entries[1].a"), "{refused}");
    let listed = profiles(head.ok(CoreCommand::ListProfiles).await.1);
    assert!(listed.is_empty());

    // Positive control: side by side, the same two entries save.
    let apart = entries_draft(
        &peer,
        vec![
            entry(RootKindView::Folder, &head.path_text("notes"), "/sdcard/a"),
            entry(RootKindView::Folder, &head.path_text("sub"), "/sdcard/b"),
        ],
    );
    let saved = profiles(
        head.ok(CoreCommand::SaveProfile {
            name: "Nested".to_owned(),
            draft: apart,
        })
        .await
        .1,
    );
    assert_eq!(head_profile(&saved, "Nested").entries.len(), 2);
}

#[tokio::test]
async fn a_two_entry_profile_lists_every_entry_with_its_own_id_and_check() {
    let mut head = Head::new("studio").await;
    let peer = seed_device(&head, "phone");
    write(&head.path("docs/todo.md"), "x");
    let two = entries_draft(
        &peer,
        vec![
            entry(
                RootKindView::File,
                &head.path_text("docs/todo.md"),
                "/sdcard/todo.md",
            ),
            entry(
                RootKindView::File,
                &head.path_text("gone/list.md"),
                "/sdcard/list.md",
            ),
        ],
    );
    let saved = profiles(
        head.ok(CoreCommand::SaveProfile {
            name: "Two".to_owned(),
            draft: two,
        })
        .await
        .1,
    );
    let listed = head_profile(&saved, "Two");
    let [todo, list] = &listed.entries[..] else {
        panic!("expected two entries");
    };
    assert_eq!(
        (todo.kind, list.kind),
        (RootKindView::File, RootKindView::File)
    );
    assert_eq!(todo.local_root, head.path_text("docs/todo.md"));
    assert_eq!(list.remote_root, "/sdcard/list.md");
    assert_ne!(todo.entry_id, list.entry_id);
    // A readable file in a writable folder is usable; one whose folder is
    // gone is not.
    assert_eq!(todo.local_root_refusal, None);
    assert!(
        list.local_root_refusal
            .as_deref()
            .is_some_and(|why| why.contains("gone")),
        "{:?}",
        list.local_root_refusal
    );
    assert_eq!(listed.last_run, LastRunView::Settled);

    // The first entry's run finished with a write still held: the profile
    // says so.
    let state = StateDir::new(head.state());
    let entry_id = |id: &str| EntryId::parse(id).unwrap_or_else(|error| panic!("{error}"));
    let pair = MarkerPair {
        a: todo.local_root.clone(),
        b: "peer://phone:/sdcard/todo.md".to_owned(),
    };
    RunMarker::new(state.run_marker(&entry_id(&todo.entry_id)))
        .create(
            &pair,
            &MarkerRecord::Held(dsync_domain::UnfinishedApply::default()),
        )
        .unwrap_or_else(|error| panic!("{error}"));
    let listed = profiles(head.ok(CoreCommand::ListProfiles).await.1);
    assert_eq!(
        head_profile(&listed, "Two").last_run,
        LastRunView::WriteHeld
    );

    // The second entry's run died: that is what the profile says, the
    // more pressing of the two.
    write(&state.run_marker(&entry_id(&list.entry_id)), "");
    let listed = profiles(head.ok(CoreCommand::ListProfiles).await.1);
    assert_eq!(head_profile(&listed, "Two").last_run, LastRunView::Died);
    assert!(
        unsaved(&listed).is_empty(),
        "the profile claims both markers"
    );

    // With the profile gone, nothing claims them: both are listed as runs
    // no profile has, the one that names its pair with it.
    let listed = profiles(
        head.ok(CoreCommand::DeleteProfile {
            name: "Two".to_owned(),
        })
        .await
        .1,
    );
    let mut unsaved: Vec<_> = unsaved(&listed)
        .into_iter()
        .map(|run| {
            (
                run.entry_id.clone(),
                run.pair
                    .as_ref()
                    .map(|pair| (pair.a.clone(), pair.b.clone())),
                run.last_run,
            )
        })
        .collect();
    unsaved.sort_by_key(|run| run.1.is_none());
    assert_eq!(
        unsaved,
        [
            (
                todo.entry_id.clone(),
                Some((pair.a, pair.b)),
                LastRunView::WriteHeld
            ),
            (list.entry_id.clone(), None, LastRunView::Died),
        ]
    );
}

fn unsaved(listed: &[ProfileEntry]) -> Vec<&UnsavedRunView> {
    listed
        .iter()
        .filter_map(|entry| match entry {
            ProfileEntry::Unsaved(run) => Some(run),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn clearing_an_entry_archive_leaves_the_other_entry_archives() {
    let mut head = Head::new("studio").await;
    let peer = seed_device(&head, "phone");
    let two = entries_draft(
        &peer,
        vec![
            entry(RootKindView::Folder, &head.path_text("a"), "/sdcard/a"),
            entry(RootKindView::Folder, &head.path_text("b"), "/sdcard/b"),
        ],
    );
    let saved = profiles(
        head.ok(CoreCommand::SaveProfile {
            name: "Two".to_owned(),
            draft: two,
        })
        .await
        .1,
    );
    let ids: Vec<String> = head_profile(&saved, "Two")
        .entries
        .iter()
        .map(|entry| entry.entry_id.clone())
        .collect();
    let state = StateDir::new(head.state());
    for id in &ids {
        let id = EntryId::parse(id).unwrap_or_else(|error| panic!("{error}"));
        for side in [dsync_domain::Side::A, dsync_domain::Side::B] {
            write(&state.archive_log(&id, side), "");
        }
    }
    let ReplyResult::Archives(all) = head.ok(CoreCommand::ListArchives).await.1 else {
        panic!("expected the archives");
    };
    assert_eq!(all.len(), 4);

    let clear = CoreCommand::ClearArchive {
        entry_id: ids[0].clone(),
    };
    let ReplyResult::Archives(left) = head.ok(clear).await.1 else {
        panic!("expected the archives");
    };
    assert_eq!(left.len(), 2);
    assert!(left.iter().all(|archive| archive.entry_id == ids[1]));
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
