//! `stage` and `take_landed` through `RemoteReplica` <-> `ReplicaServer`
//! against a far `LocalReplica` opened with no spool: the stage is refused
//! once its body is taken, nothing lands, and there is nothing to report.

use std::fs;

use dsync_core::{Body, Replica, ReplicaError, body_channel};
use dsync_domain::{Precondition, Side};

use crate::replica::served::Served;
use crate::replica::support::{Site, path, source_of, with_deadline};

/// Past one body's credit, so a far side that stopped taking it would
/// leave the sender waiting rather than finished.
const CHUNK: usize = 300 * 1024;
const CHUNKS: usize = 3;

fn entries_under(dir: &std::path::Path) -> Vec<String> {
    fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

#[tokio::test]
async fn a_stage_to_a_replica_with_no_spool_is_refused_its_body_taken_and_nothing_written() {
    let site = Site::new();
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();
    let content = vec![3u8; CHUNK * CHUNKS];
    let (sender, body) = body_channel(1);
    let chunks = content.clone();
    let feeder = tokio::spawn(async move {
        for chunk in chunks.chunks(CHUNK) {
            sender.send(chunk.to_vec()).await?;
        }
        sender.finish().await
    });

    let staged = with_deadline(
        "stage",
        b.stage(
            &path("d/s.bin"),
            body,
            source_of(&content, 0o644),
            Precondition::Absent,
        ),
    )
    .await;

    assert!(
        matches!(&staged, Err(ReplicaError::Refused(why)) if why.contains("no spool")),
        "{staged:?}"
    );
    // The far side took the body whole before refusing: every chunk and
    // its end were accepted.
    with_deadline("feeder", feeder).await.unwrap().unwrap();
    // Nothing under the root: no file, no folder, no staging temp.
    assert_eq!(entries_under(&site.root(Side::B)), Vec::<String>::new());

    // Positive control: the same session's write does land there.
    with_deadline(
        "write",
        b.write(
            &path("d/s.bin"),
            Body::from_bytes(content.clone()),
            source_of(&content, 0o644),
            Precondition::Absent,
        ),
    )
    .await
    .unwrap();
    assert_eq!(site.get(Side::B, "d/s.bin"), content);
    served.close().await;
}

#[tokio::test]
async fn take_landed_answers_at_once_with_nothing_when_nothing_is_staged() {
    let site = Site::new();
    let served = Served::new(&site, Side::B).await;
    let b = served.replica.as_ref();
    with_deadline("hello", b.hello()).await.unwrap();

    let landings = with_deadline("take_landed", b.take_landed()).await.unwrap();

    assert!(landings.landed.is_empty(), "{:?}", landings.landed);
    assert_eq!(landings.queued, 0);
    // Ready at once on the initiator: the far side settles its own.
    with_deadline("settle", b.settle()).await;
    served.close().await;
}
