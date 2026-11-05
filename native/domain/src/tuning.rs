//! Every named threshold of the engine, in one place (plan D2).

use std::time::Duration;

use crate::jobs::Jobs;
use crate::peek_limits::PeekLimits;

/// The engine's thresholds as named values, never inline literals.
/// [`Tuning::DEFAULT`] is what ships; a test may build a smaller one
/// (a shorter heartbeat, a tiny budget) to reach an edge quickly.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Tuning {
    /// Blocking writer threads receiving files (measured at the FUSE
    /// create floor by the spike).
    pub writers: usize,
    /// Actions the apply keeps writing at once, each from its write's
    /// request to its answer (SPEC §7.1). Not [`Tuning::writers`]: against
    /// a remote replica an action holds its place for the round trip as
    /// well as the far writer's work, so the two are sized apart.
    pub apply_in_flight: usize,
    /// Actions per archive commit batch.
    pub commit_batch: usize,
    /// Outstanding requests per replica session (SPEC §4.2 window): the
    /// read-ahead's streams, each holding a slot for its whole body on a
    /// remote source, plus a lead of eight for commits, plus one for
    /// `take_landed`'s long poll, which holds its place while open and
    /// must not eat the commits' lead.
    pub request_window: usize,
    /// Served reads one process sends at once, across every session it
    /// serves (SPEC §4.2): each holds a blocking thread until its body is
    /// over, parked on its peer's credit. Four sessions' windows, so one
    /// session never takes every place, and well under tokio's 512
    /// blocking threads, so the rest of the process keeps its own.
    pub served_reads: usize,
    /// Chunk size a streamed body is read ahead and sent in; also what the
    /// apply's read-ahead reserves for one source read (SPEC §7.2).
    pub read_ahead_chunk_bytes: usize,
    /// Bytes the apply's read-ahead may reserve across every source read
    /// open at once (SPEC §7.2).
    pub read_ahead_budget_bytes: usize,
    /// Actions the apply may have under way at once, source reads started
    /// ahead of their writes included: the actions in flight plus a lead
    /// of eight (SPEC §7.2's 40 open reads).
    pub read_ahead_streams: usize,
    /// Buffer a file is read into for sending, one chunk per read (plan
    /// D3: at least 256 KiB, the size the scanner hashes with).
    pub read_buffer_bytes: usize,
    /// Bytes a replica's spool may hold staged and not yet landed, at most
    /// (SPEC §4.2's `stage`).
    pub spool_bytes: u64,
    /// Free space a spool leaves on its volume: it never takes room the
    /// rest of the device needs.
    pub spool_reserve_bytes: u64,
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
    /// Deadline, from accept, for a listener to have the peer's whole TLS
    /// ClientHello (SPEC §4.4). Inside [`Tuning::handshake`] and far
    /// shorter: a dialer sends its hello the moment it connects, so a
    /// socket silent this long is idle and gives its slot back early.
    pub client_hello: Duration,
    /// How long a peer listener waits for a session a reclaim ended to
    /// let go of its replica before serving the dialer that claimed it,
    /// from when that session's spool is first seen not busy - nothing
    /// queued, nothing on a writer (SPEC §4.3); one still landing is
    /// waited on for as long as it drains. Checked each
    /// [`Tuning::heartbeat`].
    pub reclaim_wait: Duration,
    /// The wait before a dropped `peer://` entry's first re-dial; each
    /// further one waits twice the last, up to
    /// [`Tuning::reconnect_backoff_max`].
    pub reconnect_backoff: Duration,
    pub reconnect_backoff_max: Duration,
    /// How long after a drop its entry may still be re-dialled: no wait
    /// is started that would end past it. A re-run that gets past its
    /// locks opens a fresh one for the next drop.
    pub reconnect_window: Duration,
    /// Re-dials one entry may make in all, never reset: a link that flaps
    /// forever still ends.
    pub reconnects_per_entry: u32,
    /// Concurrent connections not yet authenticated.
    pub unauthenticated_connections: usize,
    /// Of those, how many one address may hold at once (SPEC §4.4): past
    /// it a connection is closed at accept without taking one of the
    /// [`Tuning::unauthenticated_connections`].
    pub unauthenticated_per_address: usize,
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
    /// What a review's diff page may read of a file.
    pub peek: PeekLimits,
}

impl Tuning {
    pub const DEFAULT: Tuning = Tuning {
        writers: 16,
        apply_in_flight: 32,
        commit_batch: 64,
        // The read-ahead's streams, the commits' lead, `take_landed`.
        request_window: 40 + 8 + 1,
        served_reads: 4 * (40 + 8),
        read_ahead_chunk_bytes: 64 * 1024,
        read_ahead_budget_bytes: 1024 * 1024,
        read_ahead_streams: 32 + 8,
        read_buffer_bytes: 256 * 1024,
        spool_bytes: 1024 * 1024 * 1024,
        spool_reserve_bytes: 512 * 1024 * 1024,
        writer_buffer_bytes: 16 * 1024 * 1024,
        heartbeat: Duration::from_secs(5),
        silence_limit: Duration::from_secs(30),
        handshake: Duration::from_secs(10),
        client_hello: Duration::from_secs(3),
        reclaim_wait: Duration::from_secs(5),
        reconnect_backoff: Duration::from_secs(1),
        reconnect_backoff_max: Duration::from_secs(15),
        reconnect_window: Duration::from_secs(120),
        reconnects_per_entry: 10,
        unauthenticated_connections: 16,
        unauthenticated_per_address: 4,
        pairing_token: Duration::from_secs(5 * 60),
        scan_jobs: Jobs::DEFAULT,
        archive_buffer_lines: 256,
        archive_buffer_interval: Duration::from_secs(1),
        peer_port: 28771,
        peek: PeekLimits {
            max_bytes: 4 * 1024 * 1024,
            diff_deadline: Duration::from_millis(200),
        },
    };
}

// One session must not take every place for a served read, and the
// places must leave tokio's 512 blocking threads room for the rest.
const _: () = assert!(Tuning::DEFAULT.request_window < Tuning::DEFAULT.served_reads);
const _: () = assert!(Tuning::DEFAULT.served_reads <= 512 / 2);

// One address must not fill every unauthenticated slot.
const _: () = assert!(
    Tuning::DEFAULT.unauthenticated_per_address < Tuning::DEFAULT.unauthenticated_connections
);

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
        assert_eq!(tuning.apply_in_flight, 32);
        assert_eq!(tuning.commit_batch, 64);
        assert_eq!(tuning.request_window, 49);
        assert_eq!(tuning.served_reads, 192);
        assert_eq!(tuning.read_ahead_chunk_bytes, 1 << 16);
        assert_eq!(tuning.read_ahead_budget_bytes, 1 << 20);
        assert_eq!(tuning.read_ahead_streams, 40);
        assert!(tuning.read_ahead_streams >= tuning.apply_in_flight);
        assert!(tuning.request_window > tuning.read_ahead_streams);
        assert!(tuning.read_ahead_chunk_bytes <= tuning.read_ahead_budget_bytes);
        assert_eq!(tuning.read_buffer_bytes, 1 << 18);
        assert_eq!(tuning.spool_bytes, 1 << 30);
        assert_eq!(tuning.spool_reserve_bytes, 1 << 29);
        assert_eq!(tuning.writer_buffer_bytes, 1 << 24);
        assert_eq!(tuning.heartbeat, Duration::from_secs(5));
        assert_eq!(tuning.silence_limit, Duration::from_secs(30));
        assert_eq!(tuning.handshake, Duration::from_secs(10));
        assert_eq!(tuning.client_hello, Duration::from_secs(3));
        assert_eq!(tuning.reclaim_wait, Duration::from_secs(5));
        assert_eq!(tuning.reconnect_backoff, Duration::from_secs(1));
        assert_eq!(tuning.reconnect_backoff_max, Duration::from_secs(15));
        assert_eq!(tuning.reconnect_window, Duration::from_secs(120));
        assert_eq!(tuning.reconnects_per_entry, 10);
        assert_eq!(tuning.unauthenticated_connections, 16);
        assert_eq!(tuning.unauthenticated_per_address, 4);
        assert_eq!(tuning.pairing_token, Duration::from_secs(300));
        assert_eq!(tuning.scan_jobs.get(), 4);
        assert_eq!(tuning.archive_buffer_lines, 256);
        assert_eq!(tuning.archive_buffer_interval, Duration::from_secs(1));
        assert_eq!(tuning.peer_port, 28771);
        assert_eq!(tuning.peek.max_bytes, 1 << 22);
        assert_eq!(tuning.peek.diff_deadline, Duration::from_millis(200));
        assert!(tuning.silence_limit > tuning.heartbeat);
    }

    /// A listener answers a claim within one heartbeat - a `Draining`
    /// frame, or `Issued` - and the dialer waits for that inside its
    /// handshake bound, after the TLS handshake; at the bound the dial
    /// would time out first. Each `Draining` then moves the bound.
    #[test]
    fn a_reclaim_answers_inside_a_handshake() {
        assert!(Tuning::DEFAULT.heartbeat < Tuning::DEFAULT.handshake);
    }

    /// The hello's deadline frees an idle socket's slot early only if it
    /// ends before the handshake's.
    #[test]
    fn the_hello_deadline_is_tighter_than_the_handshake() {
        assert!(Tuning::DEFAULT.client_hello < Tuning::DEFAULT.handshake);
    }
}
