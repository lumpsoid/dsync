//! `read`: a file's bytes as a body, read on the blocking pool in
//! `read_buffer_bytes` chunks (the cases of Dart's `read_pool_test`).

use dsync_core::{Body, FileOp, LocalReplica, Reading, Replica, ReplicaError};
use dsync_domain::{Side, Tuning};

use crate::support::{Site, path, with_deadline};

/// A read buffer small enough to cross.
const BLOCK: usize = 8;

fn small_blocks(site: &Site) -> LocalReplica {
    site.replica_with(
        Side::A,
        Tuning {
            read_buffer_bytes: BLOCK,
            ..Tuning::DEFAULT
        },
    )
}

/// Every chunk of `body`, in order.
async fn chunks(mut body: Body) -> Vec<Vec<u8>> {
    let mut all = Vec::new();
    while let Some(chunk) = body.next().await.unwrap() {
        all.push(chunk);
    }
    all
}

async fn read_chunks(replica: &LocalReplica, relative: &str) -> Vec<Vec<u8>> {
    with_deadline("read", async {
        chunks(replica.read(&path(relative)).await.unwrap().body).await
    })
    .await
}

#[tokio::test]
async fn a_file_inside_the_block_comes_back_whole_in_one_chunk() {
    let site = Site::new();
    site.put(Side::A, "f", "hello");

    assert_eq!(read_chunks(&small_blocks(&site), "f").await, [b"hello"]);
}

#[tokio::test]
async fn an_empty_file_is_a_finished_body_with_no_chunks() {
    let site = Site::new();
    site.put(Side::A, "f", "");

    assert!(read_chunks(&small_blocks(&site), "f").await.is_empty());
}

#[tokio::test]
async fn a_file_past_the_block_comes_in_blocks_that_add_up_to_it() {
    let site = Site::new();
    site.put(Side::A, "f", "0123456789abcdefXYZ");

    assert_eq!(
        read_chunks(&small_blocks(&site), "f").await,
        [&b"01234567"[..], b"89abcdef", b"XYZ"]
    );
}

#[tokio::test]
async fn a_file_of_exactly_one_block_is_one_chunk_then_the_end() {
    let site = Site::new();
    site.put(Side::A, "f", "01234567");

    assert_eq!(read_chunks(&small_blocks(&site), "f").await, [b"01234567"]);
}

#[tokio::test]
async fn the_shipped_buffer_reads_at_least_256_kib_at_a_time() {
    let site = Site::new();
    let content: Vec<u8> = (0..600 * 1024).map(|i| (i % 251) as u8).collect();
    site.put(Side::A, "f", &content);

    let read = read_chunks(&site.replica(Side::A), "f").await;

    assert!(read[0].len() >= 256 * 1024, "{}", read[0].len());
    assert_eq!(read.concat(), content);
}

#[tokio::test]
async fn a_path_that_cannot_be_opened_fails_the_read_itself() {
    let site = Site::new();
    let replica = small_blocks(&site);

    let result = with_deadline("read", replica.read(&path("missing"))).await;

    assert!(matches!(
        result,
        Err(ReplicaError::File {
            op: FileOp::Read,
            ..
        })
    ));
}

#[tokio::test]
async fn many_reads_in_flight_at_once_all_complete() {
    let site = Site::new();
    let names: Vec<String> = (0..200).map(|i| format!("f{i}")).collect();
    for name in &names {
        site.put(Side::A, name, name);
    }
    let replica = small_blocks(&site);

    with_deadline("reads", async {
        // Every body opened before any is consumed: each read waits on its
        // own consumer, not on the others.
        let mut bodies = Vec::new();
        for name in &names {
            bodies.push(replica.read(&path(name)).await.unwrap().body);
        }
        for (name, body) in names.iter().zip(bodies) {
            assert_eq!(body.collect().await.unwrap(), name.as_bytes());
        }
    })
    .await;
}

#[tokio::test]
async fn a_read_settles_on_what_its_file_was_once_read() {
    let site = Site::new();
    site.put(Side::A, "f", "hello");
    let scanned = site.expect(Side::A, "f");
    let replica = site.replica(Side::A);

    let now = with_deadline("read", async {
        let Reading { body, settled } = replica.read(&path("f")).await.unwrap();
        assert_eq!(body.collect().await.unwrap(), b"hello");
        settled.after().await
    })
    .await;

    assert_eq!(scanned.check(now), Ok(()));
}
