//! How the ssh transport reaches one remote replica (SPEC §4.2).

use std::fmt;

/// One option word for the `ssh` executable (`-p`, `-i`, `-o ...`).
/// Never empty: an empty argv word reads to ssh as a second destination
/// and fails far from the profile or flag that caused it.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SshOption(String);

/// The command that starts the agent on the far side, one string for the
/// remote shell to parse (as rsync's `--rsync-path`), so
/// `XDG_STATE_HOME=/tmp/x /opt/bin/dsync` works as written. Never empty: an
/// empty one becomes a remote shell line starting with `agent`.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SshCommand(String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("it is empty")]
pub struct EmptySshValue;

impl SshOption {
    pub fn new(text: &str) -> Result<SshOption, EmptySshValue> {
        if text.is_empty() {
            return Err(EmptySshValue);
        }
        Ok(SshOption(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl SshCommand {
    /// What starts the agent when nothing names it: the bare word, found on
    /// the remote non-interactive PATH (SPEC §4.2).
    pub const DEFAULT: &str = "dsync";

    pub fn new(text: &str) -> Result<SshCommand, EmptySshValue> {
        if text.is_empty() {
            return Err(EmptySshValue);
        }
        Ok(SshCommand(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for SshCommand {
    fn default() -> Self {
        SshCommand(Self::DEFAULT.to_owned())
    }
}

impl fmt::Display for SshCommand {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// The ssh options and remote command for one replica side. Per side, not
/// per run: two remotes need not agree on where `dsync` lives or which key
/// opens them. Not part of a replica's identity (the profile id ignores
/// it): how a tree is reached says nothing about which tree it is.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct SshAccess {
    options: Vec<SshOption>,
    command: SshCommand,
}

impl SshAccess {
    pub fn new(options: Vec<SshOption>, command: SshCommand) -> SshAccess {
        SshAccess { options, command }
    }

    pub fn options(&self) -> &[SshOption] {
        &self.options
    }

    pub fn command(&self) -> &SshCommand {
        &self.command
    }

    /// This access with one run's flags folded in (SPEC §12). The command
    /// overrides; options are appended, like `--ignore`: a profile's `-i` is
    /// what makes the connection work at all, and a `--ssh-option=-v` typed
    /// once to debug must not drop it. Where an option repeats, ssh's own
    /// precedence decides.
    pub fn with_flags(&self, options: &[SshOption], command: Option<SshCommand>) -> SshAccess {
        SshAccess {
            options: [self.options.as_slice(), options].concat(),
            command: command.unwrap_or_else(|| self.command.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/dsync_core/models/ssh_access_test.dart`.

    use super::*;

    fn options(words: &[&str]) -> Vec<SshOption> {
        words
            .iter()
            .map(|w| SshOption::new(w).unwrap_or_else(|e| panic!("{e}")))
            .collect()
    }

    fn command(text: &str) -> SshCommand {
        SshCommand::new(text).unwrap_or_else(|e| panic!("{e}"))
    }

    fn words(access: &SshAccess) -> Vec<&str> {
        access.options().iter().map(SshOption::as_str).collect()
    }

    #[test]
    fn defaults_to_no_options_and_the_bare_remote_dsync() {
        let access = SshAccess::default();
        assert!(access.options().is_empty());
        assert_eq!(access.command().as_str(), "dsync");
    }

    #[test]
    fn appends_flag_options_rather_than_replacing_the_profiles() {
        let profile = SshAccess::new(options(&["-i", "/keys/id_x"]), SshCommand::default());
        let merged = profile.with_flags(&options(&["-v"]), None);
        assert_eq!(words(&merged), ["-i", "/keys/id_x", "-v"]);
    }

    #[test]
    fn a_flag_command_overrides_the_profiles() {
        let profile = SshAccess::new(vec![], command("/opt/bin/dsync"));
        let merged = profile.with_flags(&[], Some(command("/usr/bin/dsync")));
        assert_eq!(merged.command().as_str(), "/usr/bin/dsync");
    }

    #[test]
    fn no_flag_command_leaves_the_profiles_standing() {
        let profile = SshAccess::new(vec![], command("/opt/bin/dsync"));
        let merged = profile.with_flags(&options(&["-v"]), None);
        assert_eq!(merged.command().as_str(), "/opt/bin/dsync");
    }

    #[test]
    fn leaves_the_original_alone() {
        let profile = SshAccess::new(options(&["-i", "/keys/id_x"]), SshCommand::default());
        let _ = profile.with_flags(&options(&["-v"]), Some(command("other")));
        assert_eq!(words(&profile), ["-i", "/keys/id_x"]);
        assert_eq!(profile.command().as_str(), "dsync");
    }

    #[test]
    fn empty_words_are_refused() {
        assert_eq!(SshOption::new(""), Err(EmptySshValue));
        assert_eq!(SshCommand::new(""), Err(EmptySshValue));
        assert!(SshOption::new("-v").is_ok());
    }
}
