//! The facts about this host that canonicalizing a local path needs.

use std::collections::BTreeMap;

use crate::platform::Platform;

/// This process's home directory, environment and working directory, and
/// the platform whose path rules apply. Fetched by the core (the one
/// place `std::env` is read) and passed down, so every canonicalization
/// rule runs on plain values.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct HostFacts {
    platform: Platform,
    home: Option<String>,
    vars: BTreeMap<String, String>,
    cwd: String,
}

impl HostFacts {
    /// `home` is `None` when the host has none to offer; expanding a `~`
    /// then fails rather than producing a path spelled with nothing.
    pub fn new(
        platform: Platform,
        home: Option<String>,
        vars: impl IntoIterator<Item = (String, String)>,
        cwd: String,
    ) -> HostFacts {
        HostFacts {
            platform,
            home,
            vars: vars.into_iter().collect(),
            cwd,
        }
    }

    pub fn platform(&self) -> Platform {
        self.platform
    }

    pub fn home(&self) -> Option<&str> {
        self.home.as_deref()
    }

    pub fn var(&self, name: &str) -> Option<&str> {
        self.vars.get(name).map(String::as_str)
    }

    pub fn cwd(&self) -> &str {
        &self.cwd
    }
}
