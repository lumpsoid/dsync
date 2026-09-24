//! `dsync-core`: the I/O core of dsync-in-Rust - stores, replicas (local and
//! remote), transport, server, pairing and run. It calls down into
//! `dsync-domain` for every decision and never decides for itself; this
//! crate only fetches facts and executes plans. Replaces the spike
//! (`native/spike`, crate `dsync-spike`) module by module; see
//! native/NOTES.md.
