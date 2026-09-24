//! What a `sync` or `status` invocation names: a profile, or two locations.

use crate::location::{Locality, Location};
use crate::options_error::OptionsError;
use crate::platform::Platform;
use crate::profile::ProfileName;

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum SyncTarget {
    Profile(ProfileName),
    AdHoc(AdHocTarget),
}

/// Two locations typed on the command line, in typed order. Which becomes
/// side A is [`crate::EffectiveOptions::for_ad_hoc`]'s decision.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct AdHocTarget {
    first: Location,
    second: Location,
}

impl SyncTarget {
    /// `sync`'s positionals: one profile name, or two locations.
    pub fn for_sync(
        positionals: &[String],
        platform: Platform,
    ) -> Result<SyncTarget, OptionsError> {
        match positionals {
            [name] => Ok(SyncTarget::Profile(ProfileName::parse(name)?)),
            [first, second] => Ok(SyncTarget::AdHoc(AdHocTarget::parse(
                first, second, platform,
            )?)),
            _ => Err(OptionsError::SyncArity(positionals.len())),
        }
    }

    /// `status`'s positionals: exactly one profile name; it has no ad-hoc
    /// form.
    pub fn for_status(positionals: &[String]) -> Result<ProfileName, OptionsError> {
        match positionals {
            [name] => Ok(ProfileName::parse(name)?),
            _ => Err(OptionsError::StatusArity(positionals.len())),
        }
    }
}

impl AdHocTarget {
    /// Parses both locations. A mixed pair must be typed local first
    /// (DECIDED "local first"), judged syntactically: with no address list
    /// an unschemed `host:path` counts as remote, `localhost:` does not.
    /// Two remotes may come in either order.
    pub fn parse(
        first: &str,
        second: &str,
        platform: Platform,
    ) -> Result<AdHocTarget, OptionsError> {
        let first_location = Location::parse(first, platform)?;
        let second_location = Location::parse(second, platform)?;
        if first_location.locality(&[]) == Locality::Remote
            && second_location.locality(&[]) == Locality::InProcess
        {
            return Err(OptionsError::RemoteFirst {
                remote: first.to_owned(),
                local: second.to_owned(),
            });
        }
        Ok(AdHocTarget {
            first: first_location,
            second: second_location,
        })
    }

    pub fn first(&self) -> &Location {
        &self.first
    }

    pub fn second(&self) -> &Location {
        &self.second
    }

    /// Whether ordering the pair needs this machine's addresses: only an
    /// unschemed `host:path` consults them, so the core fetches them only
    /// then.
    pub fn consults_local_addresses(&self) -> bool {
        self.first.consults_local_addresses() || self.second.consults_local_addresses()
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/cli/options/sync_target_test.dart`. The two
    //! "same location" cases are refused by
    //! [`crate::EffectiveOptions::for_ad_hoc`]'s canonical check and are
    //! tested there.

    use super::*;

    fn words(words: &[&str]) -> Vec<String> {
        words.iter().map(|w| (*w).to_owned()).collect()
    }

    fn ad_hoc(first: &str, second: &str) -> Result<AdHocTarget, OptionsError> {
        AdHocTarget::parse(first, second, Platform::Unix)
    }

    #[test]
    fn one_positional_is_a_profile() {
        let target = SyncTarget::for_sync(&words(&["work"]), Platform::Unix).unwrap();
        assert_eq!(
            target,
            SyncTarget::Profile(ProfileName::parse("work").unwrap())
        );
    }

    #[test]
    fn two_positionals_are_an_ad_hoc_pair() {
        let target = SyncTarget::for_sync(&words(&["/home/a", "/home/b"]), Platform::Unix).unwrap();
        let SyncTarget::AdHoc(pair) = target else {
            panic!("not ad hoc: {target:?}");
        };
        assert_eq!(pair.first().path(), "/home/a");
        assert_eq!(pair.second().path(), "/home/b");
    }

    #[test]
    fn zero_or_three_positionals_are_refused() {
        assert_eq!(
            SyncTarget::for_sync(&[], Platform::Unix),
            Err(OptionsError::SyncArity(0))
        );
        assert_eq!(
            SyncTarget::for_sync(&words(&["a", "b", "c"]), Platform::Unix),
            Err(OptionsError::SyncArity(3))
        );
    }

    #[test]
    fn status_takes_exactly_one_profile_name() {
        assert_eq!(
            SyncTarget::for_status(&words(&["work"])),
            Ok(ProfileName::parse("work").unwrap())
        );
        assert_eq!(
            SyncTarget::for_status(&[]),
            Err(OptionsError::StatusArity(0))
        );
        assert_eq!(
            SyncTarget::for_status(&words(&["/a", "/b"])),
            Err(OptionsError::StatusArity(2))
        );
    }

    #[test]
    fn a_malformed_location_is_refused() {
        assert!(matches!(
            ad_hoc("", "/home/b"),
            Err(OptionsError::Location(_))
        ));
    }

    #[test]
    fn local_first_then_remote_is_accepted() {
        let pair = ad_hoc("~/notes", "me@phone:/sdcard/notes").unwrap();
        assert_eq!(pair.first().path(), "~/notes");
        assert!(matches!(pair.second(), Location::Ssh(ssh) if ssh.host() == "phone"));
    }

    #[test]
    fn remote_first_then_local_is_refused() {
        let error = ad_hoc("me@phone:/sdcard/notes", "~/notes").unwrap_err();
        assert!(
            error.to_string().contains("put the local path first"),
            "{error}"
        );
    }

    #[test]
    fn a_host_form_is_remote_at_parse_time_with_no_known_addresses() {
        assert!(matches!(
            ad_hoc("phone:/sdcard/notes", "~/notes"),
            Err(OptionsError::RemoteFirst { .. })
        ));
    }

    #[test]
    fn localhost_is_not_remote() {
        let pair = ad_hoc("localhost:/tmp/a", "~/notes").unwrap();
        assert!(matches!(pair.first(), Location::Ssh(ssh) if ssh.host() == "localhost"));
    }

    #[test]
    fn two_remotes_are_accepted_in_either_order() {
        let pair = ad_hoc("a@host1:/data", "b@host2:/data").unwrap();
        assert!(matches!(pair.first(), Location::Ssh(ssh) if ssh.host() == "host1"));
        assert!(pair.consults_local_addresses());
    }

    #[test]
    fn two_different_local_paths_are_accepted() {
        let pair = ad_hoc("~/notes", "~/backup").unwrap();
        assert_eq!(pair.first().path(), "~/notes");
        assert_eq!(pair.second().path(), "~/backup");
        assert!(!pair.consults_local_addresses());
    }
}
