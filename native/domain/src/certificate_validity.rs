//! An identity certificate's validity window and the expiry rule SPEC §4.4
//! attaches to it: when a fresh one is valid from and until, when to warn
//! that one is about to expire, and what to say. Pure - a window, a clock
//! reading and a threshold - so `pair list`, the run header, the head and
//! the handshake error all say the same thing from the same rule.

use std::fmt;
use std::time::{Duration, SystemTime};

use crate::peer_name::PeerName;

const DAY: Duration = Duration::from_secs(24 * 60 * 60);

/// The instants a certificate is valid from and until.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct CertificateValidity {
    not_before: SystemTime,
    not_after: SystemTime,
}

impl CertificateValidity {
    /// How far back a fresh certificate's `notBefore` sits from the moment
    /// it is issued: two hosts whose clocks disagree by a few minutes must
    /// not find each other's brand-new certificate not yet valid - a
    /// failure that looks like a pairing bug and is not one.
    pub const BACKDATE: Duration = Duration::from_secs(60 * 60);

    /// How long a freshly generated or renewed certificate is valid for.
    pub const LIFETIME: Duration = Duration::from_secs(3650 * 24 * 60 * 60);

    pub fn new(not_before: SystemTime, not_after: SystemTime) -> CertificateValidity {
        CertificateValidity {
            not_before,
            not_after,
        }
    }

    /// The window of a certificate issued (or renewed) at `now`:
    /// [`Self::BACKDATE`] before it, for [`Self::LIFETIME`].
    pub fn issued_at(now: SystemTime) -> CertificateValidity {
        let not_before = now.checked_sub(Self::BACKDATE).unwrap_or(now);
        CertificateValidity {
            not_before,
            not_after: not_before + Self::LIFETIME,
        }
    }

    pub fn not_before(&self) -> SystemTime {
        self.not_before
    }

    pub fn not_after(&self) -> SystemTime {
        self.not_after
    }

    /// Whether the certificate has expired at `now` - the handshake's own
    /// question. Flips strictly after `notAfter`.
    pub fn is_expired(&self, now: SystemTime) -> bool {
        self.not_after < now
    }

    /// The certificate's standing at `now`, or `None` while expiry is
    /// further away than `window` - the one rule every warning site
    /// consults.
    pub fn expiry_within(
        &self,
        owner: CertificateOwner,
        now: SystemTime,
        window: Duration,
    ) -> Option<CertificateExpiry> {
        let standing = match self.not_after.duration_since(now) {
            Ok(left) if left > window => return None,
            Ok(left) => Standing::ExpiresIn(left),
            Err(past) => Standing::ExpiredAgo(past.duration()),
        };
        Some(CertificateExpiry { owner, standing })
    }
}

/// Whose certificate an expiry is about.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum CertificateOwner {
    ThisHost,
    Peer(PeerName),
}

impl fmt::Display for CertificateOwner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CertificateOwner::ThisHost => f.write_str("this host"),
            CertificateOwner::Peer(name) => name.fmt(f),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Standing {
    ExpiresIn(Duration),
    ExpiredAgo(Duration),
}

/// One certificate close to (or past) its `notAfter`. Its `Display` is the
/// warning line SPEC §4.4 asks for: `certificate for NAME expires in N
/// days`, or `expired N days ago` once it has.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct CertificateExpiry {
    owner: CertificateOwner,
    standing: Standing,
}

impl CertificateExpiry {
    /// How far ahead of `notAfter` the warning starts: long enough to
    /// notice across a few weekly syncs, short enough not to be permanent
    /// background noise.
    pub const DEFAULT_WINDOW: Duration = Duration::from_secs(30 * 24 * 60 * 60);

    pub fn owner(&self) -> &CertificateOwner {
        &self.owner
    }

    pub fn is_expired(&self) -> bool {
        matches!(self.standing, Standing::ExpiredAgo(_))
    }
}

impl fmt::Display for CertificateExpiry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (verb, span, suffix) = match self.standing {
            Standing::ExpiresIn(left) => ("expires in", left, ""),
            Standing::ExpiredAgo(past) => ("expired", past, " ago"),
        };
        let days = span.as_secs() / DAY.as_secs();
        let unit = if days == 1 { "day" } else { "days" };
        write!(
            f,
            "certificate for {} {verb} {days} {unit}{suffix}",
            self.owner
        )
    }
}

#[cfg(test)]
mod tests {
    //! Every case of `test/dsync_core/identity/certificate_expiry_test.dart`.

    use super::*;

    const HOUR: Duration = Duration::from_secs(60 * 60);

    fn now() -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_790_000_000)
    }

    /// A certificate expiring `left` after [`now`] (or `past` before it).
    fn expiring_in(left: Duration) -> CertificateValidity {
        CertificateValidity::new(now() - 365 * DAY, now() + left)
    }

    fn expired_ago(past: Duration) -> CertificateValidity {
        CertificateValidity::new(now() - 365 * DAY, now() - past)
    }

    fn phone() -> CertificateOwner {
        CertificateOwner::Peer(PeerName::parse("phone").unwrap())
    }

    fn warning(validity: CertificateValidity, window: Duration) -> Option<String> {
        validity
            .expiry_within(phone(), now(), window)
            .map(|expiry| expiry.to_string())
    }

    #[test]
    fn is_silent_while_expiry_is_further_away_than_the_window() {
        let window = CertificateExpiry::DEFAULT_WINDOW;
        assert_eq!(warning(expiring_in(31 * DAY), window), None);
        // Positive control: the same query inside the window answers.
        assert!(warning(expiring_in(29 * DAY), window).is_some());
    }

    #[test]
    fn warns_naming_the_owner_and_the_days_left_inside_the_window() {
        let window = CertificateExpiry::DEFAULT_WINDOW;
        assert_eq!(
            warning(expiring_in(12 * DAY + HOUR), window).as_deref(),
            Some("certificate for phone expires in 12 days")
        );
        assert_eq!(
            warning(expiring_in(DAY + HOUR), window).as_deref(),
            Some("certificate for phone expires in 1 day")
        );
        let own = expiring_in(3 * DAY).expiry_within(CertificateOwner::ThisHost, now(), window);
        assert_eq!(
            own.map(|e| e.to_string()).as_deref(),
            Some("certificate for this host expires in 3 days")
        );
    }

    #[test]
    fn says_so_once_it_has_expired() {
        let expiry = expired_ago(4 * DAY + HOUR)
            .expiry_within(phone(), now(), CertificateExpiry::DEFAULT_WINDOW)
            .unwrap();
        assert!(expiry.is_expired());
        assert_eq!(
            expiry.to_string(),
            "certificate for phone expired 4 days ago"
        );
    }

    #[test]
    fn the_window_is_a_parameter() {
        assert!(warning(expiring_in(60 * DAY), 90 * DAY).is_some());
        assert_eq!(warning(expiring_in(60 * DAY), 7 * DAY), None);
    }

    #[test]
    fn is_expired_flips_at_not_after() {
        let validity = expiring_in(Duration::ZERO);
        assert!(!validity.is_expired(now()));
        assert!(validity.is_expired(now() + Duration::from_secs(1)));
        assert!(!validity.is_expired(now() - Duration::from_secs(1)));
    }

    #[test]
    fn a_fresh_window_is_backdated_an_hour_and_lasts_ten_years() {
        let validity = CertificateValidity::issued_at(now());
        assert_eq!(validity.not_before(), now() - HOUR);
        assert_eq!(validity.not_after(), now() - HOUR + 3650 * DAY);
        assert!(!validity.is_expired(now()));
    }
}
