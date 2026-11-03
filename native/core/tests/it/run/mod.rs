//! `Run` end to end over real replicas: its order and events, the apply's
//! stages, the missing-root rule, the delete guard, the connector, and the convergence soak -
//! local against local and against a replica served over the protocol.

mod apply;
mod changed;
mod connect;
mod entries;
mod file_entry;
mod flow;
mod mass_delete;
mod mass_overwrite;
mod missing_root;
mod out_of_space;
mod peek;
mod pipeline;
mod recent;
mod soak;
#[cfg(unix)]
mod special_files;
pub(crate) mod support;
mod unfinished;
