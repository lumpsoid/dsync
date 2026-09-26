//! `Run` end to end over real replicas: its order and events, the apply's
//! stages, the missing-root rule, the delete guard, the connector, and the convergence soak -
//! local against local and against a replica served over the protocol.

mod apply;
mod changed;
mod connect;
mod entries;
mod flow;
mod mass_delete;
mod missing_root;
mod pipeline;
mod soak;
#[cfg(unix)]
mod special_files;
mod support;
