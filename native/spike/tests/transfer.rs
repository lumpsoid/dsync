//! A whole transfer over loopback TLS: the tree lands byte for byte with its
//! mtimes, in either send order and over a tree already there; a client the
//! server did not pin is refused; a writer's failure is reported with its
//! file and OS error.

use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use dsync_spike::client::{PushOptions, push};
use dsync_spike::identity::Identity;
use dsync_spike::order::Order;
use dsync_spike::peer_pin::PeerPin;
use dsync_spike::server::{Received, ServeEvent, ServeOptions, serve};
use dsync_spike::write_error::WriteError;
use dsync_spike::write_stats::Stage;
use tokio::sync::mpsc;

type Tree = Vec<(String, Vec<u8>, SystemTime)>;

fn write_tree(root: &Path) -> Tree {
    let files = vec![
        (
            "a.txt".to_string(),
            b"hello".to_vec(),
            UNIX_EPOCH + Duration::new(1_600_000_000, 0),
        ),
        (
            "empty".to_string(),
            Vec::new(),
            UNIX_EPOCH + Duration::new(1_600_000_001, 0),
        ),
        (
            "d/e/big.bin".to_string(),
            (0..(700u32 << 10)).map(|i| (i % 251) as u8).collect(),
            UNIX_EPOCH + Duration::new(1_650_000_000, 500_000_000),
        ),
        (
            "d/small".to_string(),
            vec![7; 13 << 10],
            UNIX_EPOCH + Duration::new(1_700_000_000, 0),
        ),
    ];
    write_files(root, &files);
    files
}

/// The same paths as [write_tree], every one with new content (some
/// shorter, some longer, one emptied) and a new mtime.
fn rewrite_tree(root: &Path) -> Tree {
    let files = vec![
        (
            "a.txt".to_string(),
            b"hello, again".to_vec(),
            UNIX_EPOCH + Duration::new(1_600_000_100, 0),
        ),
        (
            "empty".to_string(),
            b"not any more".to_vec(),
            UNIX_EPOCH + Duration::new(1_600_000_101, 0),
        ),
        (
            "d/e/big.bin".to_string(),
            vec![3; 5000],
            UNIX_EPOCH + Duration::new(1_650_000_100, 7),
        ),
        (
            "d/small".to_string(),
            Vec::new(),
            UNIX_EPOCH + Duration::new(1_700_000_100, 0),
        ),
    ];
    write_files(root, &files);
    files
}

fn write_files(root: &Path, files: &Tree) {
    for (path, content, mtime) in files {
        let target = root.join(path);
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(&target, content).unwrap();
        fs::File::options()
            .write(true)
            .open(&target)
            .unwrap()
            .set_modified(*mtime)
            .unwrap();
    }
}

fn assert_landed(root: &Path, files: &Tree) {
    for (path, content, mtime) in files {
        let landed = root.join(path);
        assert_eq!(&fs::read(&landed).unwrap(), content, "{path}");
        assert_eq!(
            fs::metadata(&landed).unwrap().modified().unwrap(),
            *mtime,
            "{path}"
        );
    }
}

/// Serves one transfer of [source] into [target] and pushes it in [order].
async fn transfer(source: &Path, target: &Path, order: Order) -> anyhow::Result<Received> {
    let server = Identity::generate().unwrap();
    let client = Identity::generate().unwrap();
    let server_id = server.device_id();
    let (task, _events, port) =
        start_server(server, target, PeerPin::Device(client.device_id())).await;
    let options = PushOptions {
        dir: source.to_path_buf(),
        host: "127.0.0.1".to_string(),
        port,
        pin: PeerPin::Device(server_id),
        order,
    };
    let pushed = push(&client, options).await;
    let served = task.await.unwrap();
    if served.is_ok() {
        pushed.unwrap();
    }
    served
}

/// Starts [serve] on a free port; its task, its events, and the port.
async fn start_server(
    identity: Identity,
    root: &Path,
    allow: PeerPin,
) -> (
    tokio::task::JoinHandle<anyhow::Result<Received>>,
    mpsc::UnboundedReceiver<ServeEvent>,
    u16,
) {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let options = ServeOptions {
        root: root.to_path_buf(),
        port: 0,
        allow,
        writers: 2,
    };
    let task = tokio::spawn(async move { serve(&identity, options, tx).await });
    let port = match rx.recv().await {
        Some(ServeEvent::Ready { port, .. }) => port,
        other => panic!("expected Ready, got {other:?}"),
    };
    (task, rx, port)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_tree_arrives_whole_with_its_mtimes() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    let files = write_tree(source.path());
    let server = Identity::generate().unwrap();
    let client = Identity::generate().unwrap();
    let server_id = server.device_id();
    let (task, mut events, port) =
        start_server(server, target.path(), PeerPin::Device(client.device_id())).await;

    let options = PushOptions {
        dir: source.path().to_path_buf(),
        host: "127.0.0.1".to_string(),
        port,
        pin: PeerPin::Device(server_id.clone()),
        order: Order::Spread,
    };
    let report = push(&client, options).await.unwrap();
    let received = task.await.unwrap().unwrap();
    let metrics = received.metrics;

    assert_eq!(report.server, server_id);
    assert_eq!(metrics.files, 4);
    assert_eq!(report.metrics.files, 4);
    let total: u64 = files.iter().map(|f| f.1.len() as u64).sum();
    assert_eq!(metrics.bytes, total);
    assert_landed(target.path(), &files);
    assert_eq!(received.writes.files, 4);
    assert_eq!(received.writes.stage(Stage::Create).count, 4);
    assert_eq!(received.writes.stage(Stage::Open).count, 0);

    let mut done = 0;
    let mut connected = None;
    while let Ok(event) = events.try_recv() {
        match event {
            ServeEvent::FileDone { .. } => done += 1,
            ServeEvent::Connected { peer } => connected = Some(peer),
            _ => {}
        }
    }
    assert_eq!(done, 4);
    assert_eq!(connected, Some(client.device_id()));
    assert_eq!(received.peer, client.device_id());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_client_the_server_did_not_pin_is_refused_and_nothing_is_written() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    write_tree(source.path());
    let server = Identity::generate().unwrap();
    let client = Identity::generate().unwrap();
    let pinned = Identity::generate().unwrap();
    let server_id = server.device_id();
    let (task, _events, port) =
        start_server(server, target.path(), PeerPin::Device(pinned.device_id())).await;

    let options = PushOptions {
        dir: source.path().to_path_buf(),
        host: "127.0.0.1".to_string(),
        port,
        pin: PeerPin::Device(server_id),
        order: Order::Spread,
    };
    assert!(push(&client, options).await.is_err());
    assert!(task.await.unwrap().is_err());
    assert_eq!(fs::read_dir(target.path()).unwrap().count(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn walk_order_lands_the_same_tree() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    let files = write_tree(source.path());
    transfer(source.path(), target.path(), Order::Walk)
        .await
        .unwrap();
    assert_landed(target.path(), &files);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_second_push_overwrites_every_file_in_place() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    write_tree(source.path());
    transfer(source.path(), target.path(), Order::Spread)
        .await
        .unwrap();

    let files = rewrite_tree(source.path());
    let received = transfer(source.path(), target.path(), Order::Spread)
        .await
        .unwrap();

    assert_landed(target.path(), &files);
    let writes = received.writes;
    assert_eq!(writes.files, 4);
    assert_eq!(writes.stage(Stage::Open).count, 4);
    assert_eq!(writes.stage(Stage::Create).count, 0);
    assert_eq!(writes.stage(Stage::Rename).count, 0);
    assert_eq!(writes.stage(Stage::Mkdir).count, 0);
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn an_overwrite_replaces_a_hard_linked_or_read_only_file_and_leaves_its_other_names() {
    use std::os::unix::fs::PermissionsExt;

    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    write_tree(source.path());
    transfer(source.path(), target.path(), Order::Spread)
        .await
        .unwrap();
    let linked = target.path().join("a.txt");
    let other_name = outside.path().join("a.txt");
    fs::hard_link(&linked, &other_name).unwrap();
    let read_only = target.path().join("d/small");
    fs::set_permissions(&read_only, fs::Permissions::from_mode(0o444)).unwrap();

    let files = rewrite_tree(source.path());
    let received = transfer(source.path(), target.path(), Order::Spread)
        .await
        .unwrap();

    assert_landed(target.path(), &files);
    assert_eq!(fs::read(&other_name).unwrap(), b"hello");
    assert!(received.writes.stage(Stage::Rename).count >= 1);
    let leftovers: Vec<_> = walk_names(target.path())
        .into_iter()
        .filter(|name| name.contains("dsync-rs-tmp"))
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn a_root_that_is_not_writable_fails_with_the_file_and_the_os_error() {
    use std::os::unix::fs::PermissionsExt;

    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    write_tree(source.path());
    fs::set_permissions(target.path(), fs::Permissions::from_mode(0o555)).unwrap();
    if fs::write(target.path().join("probe"), b"").is_ok() {
        eprintln!("skipped: this user can write a read-only directory (root?)");
        return;
    }

    let error = transfer(source.path(), target.path(), Order::Walk)
        .await
        .unwrap_err();
    fs::set_permissions(target.path(), fs::Permissions::from_mode(0o755)).unwrap();

    let write = error
        .downcast_ref::<WriteError>()
        .unwrap_or_else(|| panic!("not a WriteError: {error:#}"));
    assert!(
        matches!(write.stage, Stage::Mkdir | Stage::Create),
        "{write}"
    );
    assert_eq!(write.kind(), std::io::ErrorKind::PermissionDenied);
    assert_eq!(write.os_code(), Some(13));
    let message = format!("{error:#}");
    assert!(message.contains(write.path.as_str()), "{message}");
    assert!(message.contains("os error 13"), "{message}");
}

fn walk_names(root: &Path) -> Vec<String> {
    let mut names = Vec::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        for entry in fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() {
                dirs.push(entry.path());
            }
            names.push(entry.file_name().to_string_lossy().into_owned());
        }
    }
    names
}
