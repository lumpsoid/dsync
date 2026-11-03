//! The built `dsync` driven as a user drives it, with the Rust binary on
//! both ends (plan OQ2): the Dart CLI's end-to-end scenarios - trees,
//! signals, exit codes, the stderr wording scripts rely on, replica
//! contents, and archives read back through the Rust store.

mod support;

mod agent_stdio;
mod archive;
mod commands;
mod dirs;
mod entries;
#[cfg(unix)]
mod folder_in_use;
#[cfg(unix)]
mod interactive;
mod mass_delete;
mod mass_overwrite;
mod output;
mod pair;
#[cfg(unix)]
mod pairing;
#[cfg(unix)]
mod peer;
#[cfg(unix)]
mod real_ssh;
#[cfg(unix)]
mod remote;
#[cfg(unix)]
mod signals;
#[cfg(unix)]
mod stop_deadline;
mod timings;
#[cfg(unix)]
mod unix_socket;
