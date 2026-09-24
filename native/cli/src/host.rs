//! The facts about this host, read once, at the top of `main`: nothing in
//! the core reads the environment, and nothing below `main` reads it
//! either.

use std::env;

use dsync_domain::{HostFacts, Platform};
use time::UtcOffset;

use crate::failure::Failure;

/// This process's environment and the clock's zone.
pub struct Host {
    pub facts: HostFacts,
    /// Where the run header's timestamps are shown. UTC where the platform
    /// will not say.
    pub utc_offset: UtcOffset,
}

impl Host {
    /// Reads the environment, working directory and local UTC offset.
    ///
    /// Must run before any other thread starts: the offset can only be read
    /// soundly from a single-threaded process on unix. Fails only when the
    /// working directory cannot be read (it was deleted under the shell):
    /// a relative location would otherwise resolve against nothing.
    pub fn read() -> Result<Host, Failure> {
        let utc_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
        let vars: Vec<(String, String)> = env::vars_os()
            .filter_map(|(name, value)| Some((name.into_string().ok()?, value.into_string().ok()?)))
            .collect();
        let home = vars
            .iter()
            .find(|(name, _)| name == "HOME")
            .map(|(_, value)| value.clone());
        let cwd = env::current_dir()
            .map_err(|error| Failure::error(format!("cannot read the working directory: {error}")))?
            .to_string_lossy()
            .into_owned();
        Ok(Host {
            facts: HostFacts::new(Platform::HOST, home, vars, cwd),
            utc_offset,
        })
    }

    /// This machine's name, for a device identity generated here.
    pub fn name() -> String {
        gethostname::gethostname().to_string_lossy().into_owned()
    }
}
