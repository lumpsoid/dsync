//! A peer:// session's token (SPEC §4.2): issued by the listener to each
//! connection it serves, held by the dialer, and presented on its next
//! dial so the listener can end the session the token names - the one
//! this dialer held when its link dropped - instead of waiting out its
//! silence limit. It lives exactly as long as that session.

use std::fmt;

use ring::rand::{SecureRandom, SystemRandom};
use subtle::ConstantTimeEq;

/// 16 random bytes. No `PartialEq`: the only comparison made against a
/// token is [`SessionToken::is`], in constant time. `Debug` hides it.
#[derive(Clone)]
pub struct SessionToken([u8; SessionToken::LEN]);

impl SessionToken {
    pub(crate) const LEN: usize = 16;

    pub(crate) fn generate() -> SessionToken {
        let mut bytes = [0u8; SessionToken::LEN];
        SystemRandom::new()
            .fill(&mut bytes)
            .expect("the system random source is available");
        SessionToken(bytes)
    }

    pub(crate) fn from_bytes(bytes: [u8; SessionToken::LEN]) -> SessionToken {
        SessionToken(bytes)
    }

    pub(crate) fn as_bytes(&self) -> &[u8; SessionToken::LEN] {
        &self.0
    }

    /// Whether `other` is this token, compared in constant time.
    pub(crate) fn is(&self, other: &SessionToken) -> bool {
        self.0.ct_eq(&other.0).into()
    }
}

impl fmt::Debug for SessionToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SessionToken(..)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_tokens_differ_and_each_is_itself() {
        let (one, two) = (SessionToken::generate(), SessionToken::generate());
        assert!(!one.is(&two));
        assert!(one.is(&one.clone()));
        assert!(one.is(&SessionToken::from_bytes(*one.as_bytes())));
    }

    #[test]
    fn debug_hides_the_bytes() {
        let token = SessionToken::from_bytes([0xab; SessionToken::LEN]);
        assert_eq!(format!("{token:?}"), "SessionToken(..)");
    }
}
