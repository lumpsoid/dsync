//! `dsync-domain`: the pure core of dsync-in-Rust - values, rules,
//! reconcile, planning and exchange math. No I/O, no tokio: every rule here
//! is testable with plain values, and "fetching never decides; deciding
//! never fetches" (CLAUDE.md). `dsync-core` (native/core) is the I/O shell
//! that calls down into this crate for verdicts.
