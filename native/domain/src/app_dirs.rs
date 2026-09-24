//! Where dsync keeps its state (archives, locks, run markers, identity,
//! pairings; SPEC §8.3) and its configuration (profiles; SPEC §12), as a
//! pure function of the host's facts. The core reads the environment once
//! into a [`HostFacts`] and passes it down; nothing here reads it.

use std::path::PathBuf;

use crate::host_facts::HostFacts;

/// The directory name every rule below appends (plan D0).
///
/// `dsync`: the Rust core is the only core now. Every store still refuses a
/// file with a foreign or older schema, naming it and saying to delete it,
/// which is what a Dart-era file left behind in this directory hits.
pub const DIR_LEAF: &str = "dsync";

/// A directory path given outright: never empty, because an empty one
/// would resolve every state file relative to whatever directory the
/// process started in - `/` for a supervised service.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct DirPath(String);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("a directory path must not be empty")]
pub struct EmptyDirPath;

impl DirPath {
    pub fn parse(text: &str) -> Result<DirPath, EmptyDirPath> {
        if text.is_empty() {
            return Err(EmptyDirPath);
        }
        Ok(DirPath(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Which platform convention places the state and config directories.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum DirRule {
    /// `$XDG_STATE_HOME` / `$XDG_CONFIG_HOME`, else `~/.local/state` /
    /// `~/.config`. Linux, and the Android CLI under Termux, which sets
    /// `HOME` to its own sandbox.
    Xdg,
    /// `~/Library/Application Support` for both: macOS has no
    /// config/state split and no XDG variables to defer to.
    MacOs,
    /// `%LOCALAPPDATA%` for state and the roaming `%APPDATA%` for config:
    /// profiles follow a user between machines, archives and identity
    /// must not. Neither is re-derived from another variable when absent -
    /// that would guess at a path Windows did not hand over.
    Windows,
    /// The app's own support directory, resolved by the mobile head
    /// (Android has no variable for it; iOS's `HOME` is convention, not
    /// contract) and handed in.
    HostSupplied(DirPath),
}

impl DirRule {
    /// The rule for a process on this desktop OS. The mobile heads build
    /// [`DirRule::HostSupplied`] instead.
    pub const HOST: DirRule = if cfg!(target_os = "macos") {
        DirRule::MacOs
    } else if cfg!(windows) {
        DirRule::Windows
    } else {
        DirRule::Xdg
    };
}

/// How the state directory is chosen: by a platform rule, or named
/// outright (`--state-dir`, SPEC §11.2) and used verbatim, with no leaf
/// appended - the flag's value is the path that appears on disk.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum StateDirChoice {
    Rule(DirRule),
    Explicit(DirPath),
}

/// No variable the rule reads is set, so there is no sane answer - rather
/// than a path spelled with nothing in it.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("Cannot locate the dsync {dir} directory: {missing}")]
pub struct DirError {
    dir: &'static str,
    missing: &'static str,
}

/// The state directory `choice` resolves to on `host`.
pub fn state_dir(choice: &StateDirChoice, host: &HostFacts) -> Result<PathBuf, DirError> {
    const DIR: &str = "state";
    let base = match choice {
        StateDirChoice::Explicit(path) => return Ok(PathBuf::from(path.as_str())),
        StateDirChoice::Rule(rule) => match rule {
            DirRule::Xdg => match set(host.var("XDG_STATE_HOME")) {
                Some(base) => base.to_owned(),
                None => format!(
                    "{}/.local/state",
                    home(host, DIR, "neither XDG_STATE_HOME nor HOME is set")?
                ),
            },
            DirRule::MacOs => application_support(host, DIR)?,
            DirRule::Windows => variable(host, DIR, "LOCALAPPDATA", "LOCALAPPDATA is not set")?,
            DirRule::HostSupplied(base) => base.as_str().to_owned(),
        },
    };
    Ok(PathBuf::from(format!("{base}/{DIR_LEAF}")))
}

/// The config directory `rule` resolves to on `host`.
pub fn config_dir(rule: &DirRule, host: &HostFacts) -> Result<PathBuf, DirError> {
    const DIR: &str = "config";
    let base = match rule {
        DirRule::Xdg => match set(host.var("XDG_CONFIG_HOME")) {
            Some(base) => base.to_owned(),
            None => format!(
                "{}/.config",
                home(host, DIR, "neither XDG_CONFIG_HOME nor HOME is set")?
            ),
        },
        DirRule::MacOs => application_support(host, DIR)?,
        DirRule::Windows => variable(host, DIR, "APPDATA", "APPDATA is not set")?,
        DirRule::HostSupplied(base) => base.as_str().to_owned(),
    };
    Ok(PathBuf::from(format!("{base}/{DIR_LEAF}")))
}

/// An unset and an empty value are the same: nothing to build on.
fn set(value: Option<&str>) -> Option<&str> {
    value.filter(|value| !value.is_empty())
}

fn home<'a>(
    host: &'a HostFacts,
    dir: &'static str,
    missing: &'static str,
) -> Result<&'a str, DirError> {
    set(host.home()).ok_or(DirError { dir, missing })
}

fn application_support(host: &HostFacts, dir: &'static str) -> Result<String, DirError> {
    Ok(format!(
        "{}/Library/Application Support",
        home(host, dir, "HOME is not set")?
    ))
}

fn variable(
    host: &HostFacts,
    dir: &'static str,
    name: &str,
    missing: &'static str,
) -> Result<String, DirError> {
    set(host.var(name))
        .map(str::to_owned)
        .ok_or(DirError { dir, missing })
}

#[cfg(test)]
mod tests {
    //! The state and config dir rules (SPEC §8.3, §12), with the `dsync`
    //! leaf.

    use super::*;
    use crate::platform::Platform;

    fn host(home: Option<&str>, vars: &[(&str, &str)]) -> HostFacts {
        HostFacts::new(
            Platform::Unix,
            home.map(str::to_owned),
            vars.iter().map(|(k, v)| (k.to_string(), v.to_string())),
            "/".into(),
        )
    }

    fn state(rule: DirRule, host: &HostFacts) -> Result<PathBuf, DirError> {
        state_dir(&StateDirChoice::Rule(rule), host)
    }

    fn supplied(base: &str) -> DirRule {
        DirRule::HostSupplied(DirPath::parse(base).unwrap())
    }

    #[test]
    fn xdg_uses_the_variable_else_home_and_ignores_an_empty_one() {
        let everything = host(
            Some("/home/me"),
            &[
                ("XDG_STATE_HOME", "/xdg/state"),
                ("XDG_CONFIG_HOME", "/xdg/config"),
            ],
        );
        assert_eq!(
            state(DirRule::Xdg, &everything).unwrap(),
            PathBuf::from("/xdg/state/dsync")
        );
        assert_eq!(
            config_dir(&DirRule::Xdg, &everything).unwrap(),
            PathBuf::from("/xdg/config/dsync")
        );

        for home_only in [
            host(Some("/home/me"), &[]),
            host(
                Some("/home/me"),
                &[("XDG_STATE_HOME", ""), ("XDG_CONFIG_HOME", "")],
            ),
        ] {
            assert_eq!(
                state(DirRule::Xdg, &home_only).unwrap(),
                PathBuf::from("/home/me/.local/state/dsync")
            );
            assert_eq!(
                config_dir(&DirRule::Xdg, &home_only).unwrap(),
                PathBuf::from("/home/me/.config/dsync")
            );
        }
    }

    #[test]
    fn xdg_also_resolves_the_android_cli_under_termux() {
        let termux = host(Some("/data/data/com.termux/files/home"), &[]);
        assert_eq!(
            state(DirRule::Xdg, &termux).unwrap(),
            PathBuf::from("/data/data/com.termux/files/home/.local/state/dsync")
        );
    }

    #[test]
    fn xdg_fails_loudly_naming_what_is_missing() {
        for nothing in [host(None, &[]), host(Some(""), &[])] {
            assert_eq!(
                state(DirRule::Xdg, &nothing).unwrap_err().to_string(),
                "Cannot locate the dsync state directory: neither XDG_STATE_HOME nor HOME is set"
            );
            assert_eq!(
                config_dir(&DirRule::Xdg, &nothing).unwrap_err().to_string(),
                "Cannot locate the dsync config directory: neither XDG_CONFIG_HOME nor HOME is set"
            );
        }
    }

    #[test]
    fn macos_joins_onto_application_support_for_both_and_ignores_xdg() {
        let mac = host(
            Some("/Users/me"),
            &[
                ("XDG_STATE_HOME", "/xdg/state"),
                ("XDG_CONFIG_HOME", "/xdg/config"),
            ],
        );
        let expected = PathBuf::from("/Users/me/Library/Application Support/dsync");
        assert_eq!(state(DirRule::MacOs, &mac).unwrap(), expected);
        assert_eq!(config_dir(&DirRule::MacOs, &mac).unwrap(), expected);
    }

    #[test]
    fn macos_fails_loudly_without_home() {
        for nothing in [host(None, &[]), host(Some(""), &[])] {
            assert_eq!(
                state(DirRule::MacOs, &nothing).unwrap_err().to_string(),
                "Cannot locate the dsync state directory: HOME is not set"
            );
            assert_eq!(
                config_dir(&DirRule::MacOs, &nothing)
                    .unwrap_err()
                    .to_string(),
                "Cannot locate the dsync config directory: HOME is not set"
            );
        }
    }

    #[test]
    fn windows_state_is_localappdata_and_config_the_roaming_appdata() {
        let win = host(
            Some("C:/Users/me"),
            &[
                ("LOCALAPPDATA", "C:/Users/me/AppData/Local"),
                ("APPDATA", "C:/Users/me/AppData/Roaming"),
            ],
        );
        assert_eq!(
            state(DirRule::Windows, &win).unwrap(),
            PathBuf::from("C:/Users/me/AppData/Local/dsync")
        );
        assert_eq!(
            config_dir(&DirRule::Windows, &win).unwrap(),
            PathBuf::from("C:/Users/me/AppData/Roaming/dsync")
        );
    }

    #[test]
    fn windows_fails_loudly_and_never_falls_back_to_home_or_the_other_variable() {
        for missing in [
            host(Some("C:/Users/me"), &[("USERPROFILE", "C:/Users/me")]),
            host(
                Some("C:/Users/me"),
                &[("LOCALAPPDATA", ""), ("APPDATA", "")],
            ),
        ] {
            assert_eq!(
                state(DirRule::Windows, &missing).unwrap_err().to_string(),
                "Cannot locate the dsync state directory: LOCALAPPDATA is not set"
            );
            assert_eq!(
                config_dir(&DirRule::Windows, &missing)
                    .unwrap_err()
                    .to_string(),
                "Cannot locate the dsync config directory: APPDATA is not set"
            );
        }
        let local_only = host(None, &[("LOCALAPPDATA", "C:/L")]);
        assert!(config_dir(&DirRule::Windows, &local_only).is_err());
        assert!(state(DirRule::Windows, &local_only).is_ok());
    }

    #[test]
    fn host_supplied_joins_the_leaf_and_ignores_the_environment() {
        let noisy = host(
            Some("/home/me"),
            &[("XDG_STATE_HOME", "/xdg"), ("LOCALAPPDATA", "C:/L")],
        );
        let ios = supplied("/var/mobile/Containers/Data/Application/X/Library/Application Support");
        assert_eq!(
            state(ios.clone(), &noisy).unwrap(),
            PathBuf::from(
                "/var/mobile/Containers/Data/Application/X/Library/Application Support/dsync"
            )
        );
        let android = supplied("/data/user/0/dev.dsync/files");
        assert_eq!(
            state(android.clone(), &host(None, &[])).unwrap(),
            PathBuf::from("/data/user/0/dev.dsync/files/dsync")
        );
        assert_eq!(
            config_dir(&android, &noisy).unwrap(),
            PathBuf::from("/data/user/0/dev.dsync/files/dsync")
        );
    }

    #[test]
    fn an_explicit_state_dir_is_verbatim_and_wins_over_every_variable() {
        let noisy = host(Some("/home/me"), &[("XDG_STATE_HOME", "/xdg")]);
        let media = StateDirChoice::Explicit(DirPath::parse("/var/lib/dsync/media").unwrap());
        let photos = StateDirChoice::Explicit(DirPath::parse("/var/lib/dsync/photos").unwrap());
        assert_eq!(
            state_dir(&media, &noisy).unwrap(),
            PathBuf::from("/var/lib/dsync/media")
        );
        assert_eq!(
            state_dir(&photos, &noisy).unwrap(),
            PathBuf::from("/var/lib/dsync/photos")
        );
    }

    #[test]
    fn an_empty_supplied_or_explicit_path_is_refused() {
        assert_eq!(DirPath::parse(""), Err(EmptyDirPath));
    }
}
