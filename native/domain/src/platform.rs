//! The platform family a rule depends on, passed in as a value so every
//! branch is testable on any host (SPEC §3: "never a `Platform.isWindows`
//! read inside `core`").

/// The two platform families whose rules differ here: Windows (drive
/// letters, `\` separators, no unix sockets) and everything else.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Platform {
    Unix,
    Windows,
}

impl Platform {
    /// The platform this binary was compiled for. The one place the real
    /// platform is read; every rule takes a [`Platform`] instead.
    pub const HOST: Platform = if cfg!(windows) {
        Platform::Windows
    } else {
        Platform::Unix
    };
}
