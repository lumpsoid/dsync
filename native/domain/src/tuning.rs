//! Every named threshold of the engine, in one place (plan D2).

use std::time::Duration;

use crate::jobs::Jobs;

/// The engine's thresholds as named values, never inline literals.
/// [`Tuning::DEFAULT`] is what ships; a test may build a smaller one
/// (a shorter heartbeat, a tiny budget) to reach an edge quickly.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Tuning {
    /// Blocking writer threads receiving files (measured at the FUSE
    /// create floor by the spike).
    pub writers: usize,
    /// Actions per archive commit batch.
    pub commit_batch: usize,
    /// Intents marked ahead of their writes, one window per commit batch.
    pub mark_window: usize,
    /// Outstanding requests per replica session (SPEC §4.2 window).
    pub request_window: usize,
    /// Received-but-unprocessed bytes before the router stops reading.
    pub router_budget_bytes: usize,
    /// Chunk size a streamed body is read ahead and sent in.
    pub read_ahead_chunk_bytes: usize,
    /// Buffer a file is read into for sending, one chunk per read (plan
    /// D3: at least 256 KiB, the size the scanner hashes with).
    pub read_buffer_bytes: usize,
    /// Bytes a replica's writer pool holds received and not yet written,
    /// across every file in flight: past it, whoever feeds a write waits
    /// (the spike's measured 16 MiB).
    pub writer_buffer_bytes: usize,
    /// Interval of heartbeats on network transports.
    pub heartbeat: Duration,
    /// Silence after which a network peer is taken as gone.
    pub silence_limit: Duration,
    /// Deadline for a TLS handshake and hello.
    pub handshake: Duration,
    /// Concurrent connections not yet authenticated.
    pub unauthenticated_connections: usize,
    /// Lifetime of a pairing token.
    pub pairing_token: Duration,
    /// Scan threads (stat + hash) when neither profile nor flag says.
    pub scan_jobs: Jobs,
    /// Archive lines buffered before a flush...
    pub archive_buffer_lines: usize,
    /// ...or this long, whichever comes first.
    pub archive_buffer_interval: Duration,
    /// The peer:// listener's port when a pairing does not say (SPEC §4.4):
    /// unprivileged, outside the ephemeral range, clear of ssh, common dev
    /// servers and Syncthing.
    pub peer_port: u16,
}

impl Tuning {
    pub const DEFAULT: Tuning = Tuning {
        writers: 16,
        commit_batch: 64,
        mark_window: 64,
        request_window: 32,
        router_budget_bytes: 1024 * 1024,
        read_ahead_chunk_bytes: 64 * 1024,
        read_buffer_bytes: 256 * 1024,
        writer_buffer_bytes: 16 * 1024 * 1024,
        heartbeat: Duration::from_secs(5),
        silence_limit: Duration::from_secs(30),
        handshake: Duration::from_secs(10),
        unauthenticated_connections: 16,
        pairing_token: Duration::from_secs(5 * 60),
        scan_jobs: Jobs::DEFAULT,
        archive_buffer_lines: 256,
        archive_buffer_interval: Duration::from_secs(1),
        peer_port: 28771,
    };
}

impl Default for Tuning {
    fn default() -> Self {
        Tuning::DEFAULT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shipped_values_are_the_measured_ones() {
        let tuning = Tuning::default();
        assert_eq!(tuning.writers, 16);
        assert_eq!(tuning.commit_batch, 64);
        assert_eq!(tuning.mark_window, 64);
        assert_eq!(tuning.request_window, 32);
        assert_eq!(tuning.router_budget_bytes, 1 << 20);
        assert_eq!(tuning.read_ahead_chunk_bytes, 1 << 16);
        assert_eq!(tuning.read_buffer_bytes, 1 << 18);
        assert_eq!(tuning.writer_buffer_bytes, 1 << 24);
        assert_eq!(tuning.heartbeat, Duration::from_secs(5));
        assert_eq!(tuning.silence_limit, Duration::from_secs(30));
        assert_eq!(tuning.handshake, Duration::from_secs(10));
        assert_eq!(tuning.unauthenticated_connections, 16);
        assert_eq!(tuning.pairing_token, Duration::from_secs(300));
        assert_eq!(tuning.scan_jobs.get(), 4);
        assert_eq!(tuning.archive_buffer_lines, 256);
        assert_eq!(tuning.archive_buffer_interval, Duration::from_secs(1));
        assert_eq!(tuning.peer_port, 28771);
        assert!(tuning.silence_limit > tuning.heartbeat);
    }
}
