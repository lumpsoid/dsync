//! A whole transfer over loopback TLS: the tree lands byte for byte with its
//! mtimes, and a client the server did not pin is refused.

use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use dsync_core::client::{PushOptions, push};
use dsync_core::identity::Identity;
use dsync_core::peer_pin::PeerPin;
use dsync_core::server::{Received, ServeEvent, ServeOptions, serve};
use tokio::sync::mpsc;

fn write_tree(root: &Path) -> Vec<(String, Vec<u8>, SystemTime)> {
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
    for (path, content, mtime) in &files {
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
    files
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
    };
    let report = push(&client, options).await.unwrap();
    let received = task.await.unwrap().unwrap();
    let metrics = received.metrics;

    assert_eq!(report.server, server_id);
    assert_eq!(metrics.files, 4);
    assert_eq!(report.metrics.files, 4);
    let total: u64 = files.iter().map(|f| f.1.len() as u64).sum();
    assert_eq!(metrics.bytes, total);
    for (path, content, mtime) in &files {
        let landed = target.path().join(path);
        assert_eq!(&fs::read(&landed).unwrap(), content, "{path}");
        assert_eq!(
            fs::metadata(&landed).unwrap().modified().unwrap(),
            *mtime,
            "{path}"
        );
    }

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
    };
    assert!(push(&client, options).await.is_err());
    assert!(task.await.unwrap().is_err());
    assert_eq!(fs::read_dir(target.path()).unwrap().count(), 0);
}
