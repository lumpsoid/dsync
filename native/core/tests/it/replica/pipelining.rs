//! One connection, many operations (SPEC §4.2): replies out of order,
//! per-path order, barriers, per-stream credit, and a connection that
//! fails under outstanding operations - the pipelining cases of
//! `remote_agent_test.dart` and the backpressure cases of
//! `frame_router_test.dart`, through a real server.

use std::sync::{Arc, Mutex};

use dsync_core::{BodySender, LinkError, Replica, ReplicaError, body_channel};
use dsync_domain::{ArchiveCommit, Precondition, Side};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::replica::served::{Served, still_pending};
use crate::replica::support::{Site, meta, path, recorded, with_deadline};

/// A write of `relative` whose body stays open until the returned sender
/// finishes it.
fn held_write(served: &Served, relative: &'static str) -> (BodySender, JoinHandle<()>) {
    let (sender, body) = body_channel(4);
    let replica = served.replica.clone();
    let write = tokio::spawn(async move {
        replica
            .write(&path(relative), body, meta(0o644), Precondition::Absent)
            .await
            .unwrap();
    });
    (sender, write)
}

/// Runs `work` on its own task, recording `name` in `log` when it is done.
fn logged<F>(log: &Arc<Mutex<Vec<&'static str>>>, name: &'static str, work: F) -> JoinHandle<()>
where
    F: Future<Output = Result<(), ReplicaError>> + Send + 'static,
{
    let log = log.clone();
    tokio::spawn(async move {
        work.await.unwrap();
        log.lock().unwrap().push(name);
    })
}

async fn hello(served: &Served) {
    with_deadline("hello", served.replica.hello())
        .await
        .unwrap();
}

#[tokio::test]
async fn a_later_operation_on_another_path_completes_before_an_earlier_one() {
    let site = Site::new();
    site.put(Side::B, "other", "x");
    let served = Served::new(&site, Side::B).await;
    hello(&served).await;
    let (sender, mut write) = held_write(&served, "slow");
    // Issued after the write, answered first: the reply for `other`
    // reaches its own caller while the write's exchange is still open.
    let expect = site.expect(Side::B, "other");
    with_deadline("delete", served.replica.delete(&path("other"), expect))
        .await
        .unwrap();
    assert!(still_pending(&mut write).await);
    sender.send(b"late".to_vec()).await.unwrap();
    sender.finish().await.unwrap();
    with_deadline("write", write).await.unwrap();
    assert_eq!(site.get(Side::B, "slow"), b"late");
    served.close().await;
}

#[tokio::test]
async fn operations_on_one_path_keep_the_order_they_were_issued_in() {
    let site = Site::new();
    let served = Served::new(&site, Side::B).await;
    hello(&served).await;
    let log = Arc::new(Mutex::new(Vec::new()));
    let (sender, write) = held_write(&served, "p");
    tokio::task::yield_now().await;
    // The upsert of `p` cannot overtake the write it records.
    let replica = served.replica.clone();
    let mut commit = logged(&log, "commit", async move {
        replica
            .commit(vec![ArchiveCommit::Upsert {
                path: path("p"),
                file: recorded("p"),
            }])
            .await
    });
    assert!(still_pending(&mut commit).await);
    sender.finish().await.unwrap();
    with_deadline("write", write).await.unwrap();
    with_deadline("commit", commit).await.unwrap();
    with_deadline("unlock", served.replica.unlock())
        .await
        .unwrap();
    assert_eq!(site.archive(Side::B).get(&path("p")), Some(&recorded("p")));
    served.close().await;
}

#[tokio::test]
async fn a_barrier_drains_the_window_and_holds_what_comes_after_it() {
    let site = Site::new();
    site.put(Side::B, "q", "x");
    let served = Served::new(&site, Side::B).await;
    hello(&served).await;
    let log = Arc::new(Mutex::new(Vec::new()));
    let (sender, write) = held_write(&served, "p");
    tokio::task::yield_now().await;
    let replica = served.replica.clone();
    let mut compact = logged(&log, "compact", async move { replica.compact().await });
    tokio::task::yield_now().await;
    let replica = served.replica.clone();
    let expect = site.expect(Side::B, "q");
    let mut delete = logged(&log, "delete", async move {
        replica.delete(&path("q"), expect).await
    });
    assert!(still_pending(&mut compact).await);
    assert!(still_pending(&mut delete).await);
    assert!(site.file(Side::B, "q").exists());

    sender.finish().await.unwrap();
    with_deadline("write", write).await.unwrap();
    with_deadline("compact", compact).await.unwrap();
    with_deadline("delete", delete).await.unwrap();
    assert_eq!(*log.lock().unwrap(), ["compact", "delete"]);
    served.close().await;
}

#[tokio::test]
async fn a_tombstone_commit_is_windowed_not_a_barrier() {
    let site = Site::new();
    let served = Served::new(&site, Side::B).await;
    hello(&served).await;
    let (sender, write) = held_write(&served, "p");
    tokio::task::yield_now().await;
    with_deadline(
        "commit on another path",
        served
            .replica
            .commit(vec![ArchiveCommit::Delete(path("elsewhere"))]),
    )
    .await
    .unwrap();
    sender.finish().await.unwrap();
    with_deadline("write", write).await.unwrap();
    served.close().await;
}

#[tokio::test]
async fn a_connection_that_fails_takes_every_outstanding_operation_with_it() {
    let site = Site::new();
    site.put(Side::B, "big", vec![1u8; 4 * 1024 * 1024]);
    let served = Served::new(&site, Side::B).await;
    hello(&served).await;
    let (sender, write) = held_write_failing(&served, "w");
    let unread = with_deadline("read", served.replica.read(&path("big")))
        .await
        .unwrap();
    tokio::task::yield_now().await;
    let replica = served.replica.clone();
    let compact = tokio::spawn(async move { replica.compact().await });

    // The far side goes away mid-run.
    served.serving.abort();
    let _ = served.serving.await;

    let failed = with_deadline("write", write).await.unwrap();
    assert!(
        matches!(failed, Err(ReplicaError::Link(LinkError::Closed))),
        "{failed:?}"
    );
    let compacted = with_deadline("compact", compact).await.unwrap();
    assert!(
        matches!(compacted, Err(ReplicaError::Link(_))),
        "{compacted:?}"
    );
    // A body still arriving is cut short, never taken as a short file.
    assert!(
        with_deadline("collect", unread.body.collect())
            .await
            .is_err()
    );
    // And every later call fails at once.
    assert!(matches!(
        with_deadline(
            "later",
            served.replica.delete(&path("x"), Precondition::Absent)
        )
        .await,
        Err(ReplicaError::Link(LinkError::Closed))
    ));
    drop(sender);
}

/// [`held_write`] that hands back the write's result instead of expecting
/// success.
fn held_write_failing(
    served: &Served,
    relative: &'static str,
) -> (
    BodySender,
    JoinHandle<Result<dsync_domain::FileMeta, ReplicaError>>,
) {
    let (sender, body) = body_channel(4);
    let replica = served.replica.clone();
    let write = tokio::spawn(async move {
        replica
            .write(&path(relative), body, meta(0o644), Precondition::Absent)
            .await
    });
    (sender, write)
}

/// Reads `relative` without consuming its body, then reports whether a
/// small read issued after it gets through while the first body sits.
async fn small_read_behind_an_unread(size: usize) -> bool {
    let site = Site::new();
    site.put(Side::B, "unread", vec![3u8; size]);
    site.put(Side::B, "small", "s");
    let served = Served::new(&site, Side::B).await;
    hello(&served).await;
    let unread = with_deadline("read", served.replica.read(&path("unread")))
        .await
        .unwrap();
    // Lets the unread body fill whatever it can - its credit, the far
    // side's queue, the transport - before the small read is asked, so
    // the small read's answer is queued behind it rather than racing it.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let replica = served.replica.clone();
    let (done, mut finished) = mpsc::channel(1);
    let small = tokio::spawn(async move {
        let body = replica.read(&path("small")).await.unwrap().body;
        let bytes = body.collect().await.unwrap();
        done.send(()).await.unwrap();
        bytes
    });
    let got_through = tokio::time::timeout(std::time::Duration::from_millis(300), finished.recv())
        .await
        .is_ok();
    assert_eq!(
        with_deadline("the unread body", unread.body.collect())
            .await
            .unwrap()
            .len(),
        size
    );
    assert_eq!(with_deadline("small", small).await.unwrap(), b"s");
    served.close().await;
    got_through
}

#[tokio::test]
async fn a_body_nobody_is_taking_does_not_stall_other_exchanges() {
    // Far past the body's credit: what it holds on this side is bounded
    // by its sender, not by the connection stopping.
    assert!(small_read_behind_an_unread(8 * 1024 * 1024).await);
}
