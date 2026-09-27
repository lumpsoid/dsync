//! A served root goes through a link only to a folder granted to the peer
//! (SPEC §4.4, §5.1): the peer's `follow` rules pick the links, the grants
//! bound them. A link out of every grant is skipped by the scan, and a
//! read, write or delete through it - at the path or in a folder above -
//! is refused as that one path's failure, with nothing outside touched.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;

use dsync_core::{Body, DialedPeer, LocalReplica, Replica, ReplicaError, Symlinks};
use dsync_domain::{
    EntryId, FileMeta, Glob, Jobs, Precondition, RelPath, RuleSet, ScanEntry, Side, SkippedReason,
    Stage, Tuning,
};

use crate::support::{Host, Serving, identity, serve, somewhere, with_deadline};

const OUTSIDE: &str = "target outside the folders granted to phone";

/// The server's tree: `notes` (granted) holding `real.txt` and links -
/// `docs-link` to `docs` (granted too), `file-link` and `folder-link` to
/// `outside` and what is in it, and `sibling-link` to `notesx`, which
/// shares `notes` as a string prefix but is not beneath it. The server
/// serves `notes` to the client's dialled replica, hello'd and locked.
struct Linked {
    root: PathBuf,
    docs: PathBuf,
    outside: PathBuf,
    sibling: PathBuf,
    peer: DialedPeer,
    server: Host,
    _serving: Serving,
    _client: Host,
}

impl Linked {
    async fn new() -> Linked {
        let server = Host::new(identity("desktop"));
        let client = Host::new(identity("phone"));
        let root = server.root("notes");
        let docs = server.root("docs");
        let outside = server.root("outside");
        let sibling = server.root("notesx");
        for folder in [&root, &docs, &outside, &sibling] {
            fs::create_dir_all(folder).unwrap();
        }
        fs::write(root.join("real.txt"), "inside").unwrap();
        fs::write(docs.join("a.txt"), "granted too").unwrap();
        fs::write(outside.join("secret.txt"), "outside").unwrap();
        fs::write(sibling.join("secret.txt"), "sibling").unwrap();
        symlink(&docs, root.join("docs-link")).unwrap();
        symlink(outside.join("secret.txt"), root.join("file-link")).unwrap();
        symlink(&outside, root.join("folder-link")).unwrap();
        symlink(&sibling, root.join("sibling-link")).unwrap();
        server.pair(
            &client.identity,
            "phone",
            somewhere(),
            &[root.as_path(), docs.as_path()],
        );
        client.pair(&server.identity, "desktop", somewhere(), &[]);
        let serving = serve(&server).await;
        let peer = with_deadline(
            "dial",
            client.dial("desktop", Some(serving.at), root.to_str().unwrap()),
        )
        .await
        .unwrap();
        with_deadline("hello", peer.replica.hello()).await.unwrap();
        with_deadline("lock", peer.replica.lock()).await.unwrap();
        Linked {
            root,
            docs,
            outside,
            sibling,
            peer,
            server,
            _serving: serving,
            _client: client,
        }
    }

    async fn write(&self, path: &str) -> Result<FileMeta, ReplicaError> {
        with_deadline("write", write(&self.peer.replica, path)).await
    }

    async fn delete(&self, path: &str) -> Result<(), ReplicaError> {
        with_deadline(
            "delete",
            self.peer.replica.delete(&rel(path), Precondition::Absent),
        )
        .await
    }

    async fn read(&self, path: &str) -> Result<Vec<u8>, ReplicaError> {
        with_deadline("read", read(&self.peer.replica, path)).await
    }

    /// The two folders outside every grant are as they were set up, and
    /// every link is still a link.
    fn assert_untouched(&self) {
        for (folder, content) in [(&self.outside, "outside"), (&self.sibling, "sibling")] {
            let names: Vec<_> = fs::read_dir(folder)
                .unwrap()
                .map(|entry| entry.unwrap().file_name())
                .collect();
            assert_eq!(names, ["secret.txt"], "{}", folder.display());
            assert_eq!(
                fs::read_to_string(folder.join("secret.txt")).unwrap(),
                content
            );
        }
        for link in ["docs-link", "file-link", "folder-link", "sibling-link"] {
            let meta = fs::symlink_metadata(self.root.join(link)).unwrap();
            assert!(meta.file_type().is_symlink(), "{link}");
        }
    }

    async fn close(self) {
        with_deadline("unlock", self.peer.replica.unlock())
            .await
            .unwrap();
        with_deadline("close", self.peer.replica.close())
            .await
            .unwrap();
    }
}

async fn write(replica: &impl Replica, path: &str) -> Result<FileMeta, ReplicaError> {
    let content = b"from the peer".to_vec();
    let meta = FileMeta {
        size: content.len() as u64,
        mtime_us: 1_704_067_200_000_000,
        mode: 0o644,
    };
    replica
        .write(
            &rel(path),
            Body::from_bytes(content),
            meta,
            Precondition::Absent,
        )
        .await
}

async fn read(replica: &impl Replica, path: &str) -> Result<Vec<u8>, ReplicaError> {
    let reading = replica.read(&rel(path)).await?;
    Ok(reading.body.collect().await.unwrap())
}

fn rel(text: &str) -> RelPath {
    RelPath::parse(text).unwrap()
}

fn follow_all() -> RuleSet {
    RuleSet::new(Vec::new(), vec![Glob::new("**").unwrap()])
}

fn paths(entries: &[ScanEntry]) -> Vec<String> {
    let mut paths: Vec<_> = entries
        .iter()
        .map(|entry| entry.path.as_str().to_owned())
        .collect();
    paths.sort();
    paths
}

/// A refused write: one path's [`ReplicaError::Write`] at the probe,
/// naming the link and why.
fn assert_refused_write(written: Result<FileMeta, ReplicaError>, link: &str) {
    match written {
        Err(ReplicaError::Write(error)) => {
            assert_eq!(error.stage, Stage::Probe);
            let text = error.source.to_string();
            assert!(text.contains(link) && text.contains(OUTSIDE), "{text}");
            assert!(!ReplicaError::Write(error).ends_run());
        }
        other => panic!("not a refused write: {other:?}"),
    }
}

fn assert_refused_file<T: std::fmt::Debug>(done: Result<T, ReplicaError>, link: &str) {
    match done {
        Err(error @ ReplicaError::File { .. }) => {
            let text = error.to_string();
            assert!(text.contains(link) && text.contains(OUTSIDE), "{text}");
            assert!(!error.ends_run());
        }
        other => panic!("not a refused file operation: {other:?}"),
    }
}

#[tokio::test]
async fn a_link_to_another_granted_folder_is_followed_both_ways() {
    let linked = Linked::new().await;

    let opened = with_deadline("scan", linked.peer.replica.open_scan(&follow_all()))
        .await
        .unwrap();
    assert!(
        paths(&opened.changed.entries).contains(&"docs-link/a.txt".to_owned()),
        "{:?}",
        opened.changed.entries
    );
    assert_eq!(
        linked.read("docs-link/a.txt").await.unwrap(),
        b"granted too"
    );

    linked.write("docs-link/new.txt").await.unwrap();
    assert_eq!(
        fs::read_to_string(linked.docs.join("new.txt")).unwrap(),
        "from the peer"
    );
    linked.assert_untouched();
    linked.close().await;
}

#[tokio::test]
async fn a_peers_follow_all_is_bounded_by_its_grants() {
    let linked = Linked::new().await;

    let opened = with_deadline("scan", linked.peer.replica.open_scan(&follow_all()))
        .await
        .unwrap();

    assert_eq!(
        paths(&opened.changed.entries),
        ["docs-link/a.txt", "real.txt"]
    );
    let mut skipped: Vec<_> = opened
        .changed
        .skipped
        .iter()
        .map(|skipped| {
            assert_eq!(skipped.reason, SkippedReason::Symlink);
            assert_eq!(skipped.detail, OUTSIDE);
            skipped.path().unwrap().as_str().to_owned()
        })
        .collect();
    skipped.sort();
    assert_eq!(skipped, ["file-link", "folder-link", "sibling-link"]);
    linked.close().await;
}

#[tokio::test]
async fn a_write_through_a_link_outside_the_grants_is_refused_at_the_path_and_under_a_folder() {
    let linked = Linked::new().await;

    assert_refused_write(linked.write("file-link").await, "file-link");
    assert_refused_write(linked.write("folder-link/new.txt").await, "folder-link");
    assert_refused_write(
        linked.write("folder-link/deeper/new.txt").await,
        "folder-link",
    );
    assert_refused_write(linked.write("sibling-link/new.txt").await, "sibling-link");
    linked.assert_untouched();

    // Positive control: the same session writes an ordinary path.
    linked.write("sub/landed.txt").await.unwrap();
    assert_eq!(
        fs::read_to_string(linked.root.join("sub/landed.txt")).unwrap(),
        "from the peer"
    );
    linked.close().await;
}

#[tokio::test]
async fn a_read_delete_or_folder_removal_through_a_link_outside_the_grants_is_refused() {
    let linked = Linked::new().await;

    // No scan first: a peer can ask for any path.
    assert_refused_file(linked.read("file-link").await, "file-link");
    assert_refused_file(linked.read("folder-link/secret.txt").await, "folder-link");
    assert_refused_file(linked.read("sibling-link/secret.txt").await, "sibling-link");
    assert_refused_file(linked.delete("file-link").await, "file-link");
    assert_refused_file(linked.delete("folder-link/secret.txt").await, "folder-link");
    assert_refused_file(
        with_deadline(
            "remove empty folders",
            linked
                .peer
                .replica
                .remove_empty_dirs(&rel("folder-link/deeper/secret.txt")),
        )
        .await,
        "folder-link",
    );
    linked.assert_untouched();

    // Positive control: the same session reads an ordinary file.
    assert_eq!(linked.read("real.txt").await.unwrap(), b"inside");
    linked.close().await;
}

#[tokio::test]
async fn a_local_replica_follows_links_as_its_own_rules_say() {
    let linked = Linked::new().await;
    // Another profile than the served one's, on the same tree.
    let local = LocalReplica::open(
        dsync_core::Root::folder(linked.root.to_str().unwrap().to_owned()),
        linked.server.state(),
        EntryId::parse("fedcba9876543210fedcba9876543210").unwrap(),
        Side::A,
        Jobs::DEFAULT,
        Tuning::DEFAULT,
        Symlinks::AsRuled,
    )
    .unwrap();

    let opened = with_deadline("scan", local.open_scan(&follow_all()))
        .await
        .unwrap();
    assert_eq!(
        paths(&opened.changed.entries),
        [
            "docs-link/a.txt",
            "file-link",
            "folder-link/secret.txt",
            "real.txt",
            "sibling-link/secret.txt",
        ]
    );
    assert_eq!(
        with_deadline("read", read(&local, "folder-link/secret.txt"))
            .await
            .unwrap(),
        b"outside"
    );
    with_deadline("write", write(&local, "folder-link/new.txt"))
        .await
        .unwrap();
    assert_eq!(
        fs::read_to_string(linked.outside.join("new.txt")).unwrap(),
        "from the peer"
    );
    linked.close().await;
}
