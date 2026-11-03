//! The places for served reads across every session one process serves
//! (SPEC §4.2): a served read holds a blocking thread until its body is
//! over, parked on its peer's credit, so this bounds how many of tokio's
//! blocking threads the peers of a listener can hold between them.

use std::sync::Arc;

use dsync_domain::Tuning;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

/// [`Tuning::served_reads`] places, shared by every [`crate::ReplicaServer`]
/// given a clone: one per process, made where its serving starts.
#[derive(Clone)]
pub struct ServedReads(Arc<Semaphore>);

impl ServedReads {
    pub fn new(tuning: &Tuning) -> ServedReads {
        ServedReads(Arc::new(Semaphore::new(tuning.served_reads.max(1))))
    }

    /// A place for one read, waiting while every one is taken; the read
    /// holds it until its body is over. Places are handed out in the
    /// order they were asked for.
    pub(crate) async fn place(&self) -> Option<OwnedSemaphorePermit> {
        // Nothing closes the semaphore, so this is always `Some`.
        self.0.clone().acquire_owned().await.ok()
    }
}
