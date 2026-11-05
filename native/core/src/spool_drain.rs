//! How far a replica's spool still has to go before it is done landing
//! (SPEC §4.2): what a peer listener holding a reclaim samples from the
//! claimed session each heartbeat.

/// Samples a served session's spool drain: `None` once the session's
/// replica is gone, or while it has no spool.
pub(crate) type DrainProbe = std::sync::Arc<dyn Fn() -> Option<SpoolDrain> + Send + Sync>;

/// A spool's drain at one moment.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SpoolDrain {
    /// The bytes staged and not yet handed to a writer: falls as each
    /// chunk goes to one.
    pub queued_bytes: u64,
    /// Anything still queued or on a writer. Stays true after
    /// `queued_bytes` reaches 0, while the last landings are written,
    /// synced and renamed, and for a landing handed straight to a writer,
    /// which never counts in `queued_bytes`.
    pub busy: bool,
}
