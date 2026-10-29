//! A peer:// replica end to end: dial, hello, scan, write and commit
//! through `RemoteReplica` to a `LocalReplica` behind the listener.

use dsync_core::{Body, Replica};
use dsync_domain::{ArchiveCommit, FileMeta, FileState, Precondition, RelPath, RuleSet, Status};

use crate::peer::support::{Host, PROFILE, identity, serve, somewhere, with_deadline};

#[tokio::test]
async fn a_replica_behind_the_listener_scans_writes_and_commits() {
    let server = Host::new(identity("desktop"));
    let client = Host::new(identity("phone"));
    let root = server.root("notes");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("there.txt"), "already here").unwrap();
    server.pair(&client.identity, "phone", somewhere(), &[root.as_path()]);
    client.pair(&server.identity, "desktop", somewhere(), &[]);
    let serving = serve(&server).await;

    let dialed = with_deadline(
        "dial",
        client.dial("desktop", Some(serving.at), root.to_str().unwrap()),
    )
    .await
    .unwrap();
    let replica = dialed.replica;
    with_deadline("hello", replica.hello()).await.unwrap();
    with_deadline("lock", replica.lock()).await.unwrap();

    let opened = with_deadline("scan", replica.open_scan(&RuleSet::default()))
        .await
        .unwrap();
    let seen: Vec<_> = opened
        .changed
        .entries
        .iter()
        .filter(|entry| matches!(entry.status, Status::Created(_)))
        .map(|entry| entry.path.as_str().to_owned())
        .collect();
    assert_eq!(seen, vec!["there.txt".to_owned()]);

    let path = RelPath::parse("sent.txt").unwrap();
    let content = b"over the wire".to_vec();
    let meta = FileMeta {
        size: content.len() as u64,
        mtime_us: 1_704_067_200_000_000,
        mode: 0o644,
    };
    let landed = with_deadline(
        "write",
        replica.write(
            &path,
            Body::from_bytes(content.clone()),
            meta,
            Precondition::Absent,
        ),
    )
    .await
    .unwrap();
    let digest = ring::digest::digest(&ring::digest::SHA256, &content);
    let hash = dsync_domain::ContentHash::from_digest(digest.as_ref().try_into().unwrap());
    with_deadline(
        "commit",
        replica.commit(vec![ArchiveCommit::Upsert {
            path: path.clone(),
            file: FileState { meta: landed, hash },
        }]),
    )
    .await
    .unwrap();
    with_deadline("unlock", replica.unlock()).await.unwrap();
    with_deadline("close", replica.close()).await.unwrap();

    assert_eq!(std::fs::read(root.join("sent.txt")).unwrap(), content);
    let log = server.state().archive_log(
        &dsync_domain::EntryId::parse(PROFILE).unwrap(),
        dsync_domain::Side::B,
    );
    let archived = std::fs::read_to_string(log).unwrap();
    assert!(archived.contains("sent.txt"), "{archived}");
}
