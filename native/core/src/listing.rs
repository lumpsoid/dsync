//! A listing - a scan phase's entries or digests, the paths or buckets it
//! asks about - sent as a body of postcard items after its request or
//! reply, never inside it (SPEC §4.2). A tree's listing is far past what
//! one frame may carry, so it travels in chunks under the body's credit
//! and is decoded as they arrive: what the far side can make this end
//! hold of it, undecoded, is one chunk and one item.
//!
//! Items are concatenated with no framing of their own: postcard knows
//! where each ends, so an item may straddle two chunks.

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::body::{Body, BodyError};
use crate::credit::{Credit, Stopped};
use crate::link_error::LinkError;
use crate::replica_error::ReplicaError;
use crate::transport::Outbox;

/// How many encoded items a listing's sender gathers into one chunk.
const CHUNK_BYTES: usize = 64 * 1024;

/// The largest one item may be: a path past it is not a path any
/// platform has.
pub(crate) const MAX_ITEM_BYTES: usize = 256 * 1024;

/// The most a listing may carry in all. A million-file tree's scan is a
/// few tens of MiB; this is the old whole-reply cap, so no tree that
/// synced before paging fails now.
pub(crate) const MAX_LISTING_BYTES: usize = 1024 * 1024 * 1024;

/// A listing being taken page by page: one already in hand, or one
/// arriving as a body.
pub struct Listing<T>(Source<T>);

enum Source<T> {
    Held(Option<Vec<T>>),
    Arriving(Arriving),
}

struct Arriving {
    body: Body,
    /// The start of an item the next chunk finishes.
    partial: Vec<u8>,
    received: usize,
}

impl<T> Listing<T> {
    pub fn from_vec(items: Vec<T>) -> Listing<T> {
        Listing(Source::Held(Some(items)))
    }
}

impl<T: DeserializeOwned> Listing<T> {
    pub(crate) fn arriving(body: Body) -> Listing<T> {
        Listing(Source::Arriving(Arriving {
            body,
            partial: Vec::new(),
            received: 0,
        }))
    }

    /// The next items, `None` once the listing is over. A page may be
    /// empty: a chunk can end inside an item.
    pub async fn next_page(&mut self) -> Result<Option<Vec<T>>, ReplicaError> {
        match &mut self.0 {
            Source::Held(items) => Ok(items.take()),
            Source::Arriving(arriving) => arriving.next_page().await,
        }
    }

    pub async fn collect(mut self) -> Result<Vec<T>, ReplicaError> {
        let mut all = Vec::new();
        while let Some(page) = self.next_page().await? {
            all.extend(page);
        }
        Ok(all)
    }
}

impl Arriving {
    async fn next_page<T: DeserializeOwned>(&mut self) -> Result<Option<Vec<T>>, ReplicaError> {
        let Some(chunk) = self.body.next().await.map_err(cut)? else {
            if !self.partial.is_empty() {
                return Err(protocol("a listing that ends inside an item"));
            }
            return Ok(None);
        };
        self.received += chunk.len();
        if self.received > MAX_LISTING_BYTES {
            return Err(protocol(&format!(
                "a listing past {MAX_LISTING_BYTES} bytes"
            )));
        }
        let mut bytes = std::mem::take(&mut self.partial);
        bytes.extend_from_slice(&chunk);
        let mut page = Vec::new();
        let mut rest = bytes.as_slice();
        while !rest.is_empty() {
            match postcard::take_from_bytes::<T>(rest) {
                Ok((item, after)) => {
                    page.push(item);
                    rest = after;
                }
                Err(postcard::Error::DeserializeUnexpectedEnd) => break,
                Err(error) => {
                    return Err(protocol(&format!("an undecodable listing item: {error}")));
                }
            }
        }
        if rest.len() > MAX_ITEM_BYTES {
            return Err(protocol(&format!(
                "a listing item past {MAX_ITEM_BYTES} bytes"
            )));
        }
        self.partial = rest.to_vec();
        Ok(Some(page))
    }
}

/// A listing's body failing is the link's failure, or its sender's.
fn cut(error: BodyError) -> ReplicaError {
    ReplicaError::Link(LinkError::from(std::io::Error::from(error)))
}

fn protocol(what: &str) -> ReplicaError {
    ReplicaError::Link(LinkError::Protocol(what.to_owned()))
}

/// Sends a listing as exchange `id`'s body, as `credit` allows.
pub(crate) struct ListingWriter<'a> {
    outbox: &'a Outbox,
    id: u32,
    credit: &'a Credit,
    chunk: Vec<u8>,
}

impl<'a> ListingWriter<'a> {
    pub fn new(outbox: &'a Outbox, id: u32, credit: &'a Credit) -> ListingWriter<'a> {
        ListingWriter {
            outbox,
            id,
            credit,
            chunk: Vec::new(),
        }
    }

    pub async fn put<T: Serialize>(&mut self, item: &T) -> Result<(), Stopped> {
        self.chunk = postcard::to_extend(item, std::mem::take(&mut self.chunk))
            .expect("protocol messages always serialize");
        if self.chunk.len() >= CHUNK_BYTES {
            let full = std::mem::take(&mut self.chunk);
            self.outbox.send_chunk(self.id, full, self.credit).await?;
        }
        Ok(())
    }

    /// Every item put is the whole listing.
    pub async fn end(mut self) -> Result<(), Stopped> {
        if !self.chunk.is_empty() {
            let last = std::mem::take(&mut self.chunk);
            self.outbox.send_chunk(self.id, last, self.credit).await?;
        }
        Ok(self.outbox.end(self.id).await?)
    }

    /// Sends what `items` holds as the whole listing; a page it fails to
    /// take fails the body, which tells the far side so.
    pub async fn send<T: Serialize + DeserializeOwned>(
        mut self,
        mut items: Listing<T>,
    ) -> Result<(), Stopped> {
        loop {
            match items.next_page().await {
                Ok(Some(page)) => {
                    for item in &page {
                        self.put(item).await?;
                    }
                }
                Ok(None) => return self.end().await,
                Err(error) => {
                    let failed = std::io::Error::other(error.to_string());
                    return Ok(self.outbox.fail(self.id, &failed).await?);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::body::body_channel;
    use crate::wire;

    async fn arriving(chunks: Vec<Vec<u8>>) -> Listing<String> {
        let (sender, body) = body_channel(chunks.len() + 1);
        for chunk in chunks {
            sender.send(chunk).await.unwrap();
        }
        sender.finish().await.unwrap();
        Listing::arriving(body)
    }

    fn encoded(items: &[&str]) -> Vec<u8> {
        items
            .iter()
            .flat_map(|item| wire::encode(&item.to_string()))
            .collect()
    }

    fn refused(result: Result<Vec<String>, ReplicaError>, saying: &str) {
        match result {
            Err(ReplicaError::Link(LinkError::Protocol(why))) => {
                assert!(why.contains(saying), "{why}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[tokio::test]
    async fn items_straddling_chunks_arrive_whole_and_in_order() {
        let bytes = encoded(&["one", "two", "three"]);
        // Every split point, the item boundaries included.
        for split in 0..=bytes.len() {
            let chunks = vec![bytes[..split].to_vec(), bytes[split..].to_vec()];
            let items = arriving(chunks).await.collect().await.unwrap();
            assert_eq!(items, ["one", "two", "three"], "split at {split}");
        }
    }

    #[tokio::test]
    async fn a_listing_ending_inside_an_item_is_refused() {
        let bytes = encoded(&["one", "two"]);
        let cut = bytes[..bytes.len() - 1].to_vec();
        refused(
            arriving(vec![cut]).await.collect().await,
            "ends inside an item",
        );
    }

    #[tokio::test]
    async fn an_item_past_its_cap_is_refused_before_it_is_whole() {
        // A length prefix announcing more than an item may hold, and
        // never the bytes: refused once the cap's worth has arrived.
        let mut prefix = wire::encode(&"x".repeat(MAX_ITEM_BYTES * 2));
        prefix.truncate(MAX_ITEM_BYTES + 8);
        refused(arriving(vec![prefix]).await.collect().await, "item past");
    }

    #[tokio::test]
    async fn an_undecodable_item_is_refused() {
        // A string that is not UTF-8.
        let bytes = vec![2, 0xff, 0xfe];
        refused(arriving(vec![bytes]).await.collect().await, "undecodable");
    }

    #[tokio::test]
    async fn a_held_listing_is_one_page() {
        let mut held = Listing::from_vec(vec![1u32, 2]);
        assert_eq!(held.next_page().await.unwrap(), Some(vec![1, 2]));
        assert_eq!(held.next_page().await.unwrap(), None);
    }
}
