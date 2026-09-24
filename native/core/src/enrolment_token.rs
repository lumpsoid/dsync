//! The enrolment token's lifetime (SPEC §4.4): generated per enrolment
//! listener, compared in constant time, burned at its first redemption -
//! before the operator confirms, so a decline burns it too - and dead
//! after [`Tuning::pairing_token`](dsync_domain::Tuning) from the
//! listener's start.

use dsync_domain::EnrolmentToken;
use ring::rand::{SecureRandom, SystemRandom};
use subtle::ConstantTimeEq;
use tokio::time::Instant;

/// Why a presented token was not redeemed. Told to the operator; the
/// enrolling peer hears one answer for all three.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TokenRefusal {
    #[error("it presented the wrong enrolment token")]
    Wrong,
    #[error("it presented the enrolment token after it was already used")]
    Burned,
    #[error("it presented the enrolment token after it expired")]
    Expired,
}

pub(crate) fn generate_token() -> EnrolmentToken {
    let mut bytes = [0u8; EnrolmentToken::LEN];
    SystemRandom::new()
        .fill(&mut bytes)
        .expect("the system random source is available");
    EnrolmentToken::from_bytes(bytes)
}

/// One listener's token: live until it is redeemed once or `expires_at`
/// passes.
#[derive(Debug)]
pub(crate) struct TokenGate {
    token: EnrolmentToken,
    expires_at: Instant,
    burned: bool,
}

impl TokenGate {
    pub(crate) fn new(token: EnrolmentToken, expires_at: Instant) -> TokenGate {
        TokenGate {
            token,
            expires_at,
            burned: false,
        }
    }

    pub(crate) fn token(&self) -> &EnrolmentToken {
        &self.token
    }

    pub(crate) fn expires_at(&self) -> Instant {
        self.expires_at
    }

    pub(crate) fn is_burned(&self) -> bool {
        self.burned
    }

    /// Redeems `presented` at `now`, burning the token: whatever happens
    /// to the enrolment after this, the token cannot be redeemed again.
    /// A wrong token burns nothing (it proves nobody saw the payload).
    pub(crate) fn redeem(
        &mut self,
        presented: &[u8; EnrolmentToken::LEN],
        now: Instant,
    ) -> Result<(), TokenRefusal> {
        if !bool::from(presented.ct_eq(self.token.as_bytes())) {
            return Err(TokenRefusal::Wrong);
        }
        if self.burned {
            return Err(TokenRefusal::Burned);
        }
        if now >= self.expires_at {
            return Err(TokenRefusal::Expired);
        }
        self.burned = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    const TTL: Duration = Duration::from_secs(300);

    fn gate(at: Instant) -> TokenGate {
        TokenGate::new(
            EnrolmentToken::from_bytes([5; EnrolmentToken::LEN]),
            at + TTL,
        )
    }

    #[test]
    fn the_right_token_is_redeemed_once() {
        let now = Instant::now();
        let mut gate = gate(now);
        assert_eq!(gate.redeem(&[5; EnrolmentToken::LEN], now), Ok(()));
        assert!(gate.is_burned());
        assert_eq!(
            gate.redeem(&[5; EnrolmentToken::LEN], now),
            Err(TokenRefusal::Burned)
        );
    }

    #[test]
    fn a_wrong_token_is_refused_and_burns_nothing() {
        let now = Instant::now();
        let mut gate = gate(now);
        let mut wrong = [5; EnrolmentToken::LEN];
        wrong[15] = 6;
        assert_eq!(gate.redeem(&wrong, now), Err(TokenRefusal::Wrong));
        assert!(!gate.is_burned());
        assert_eq!(gate.redeem(&[5; EnrolmentToken::LEN], now), Ok(()));
    }

    #[test]
    fn the_token_dies_at_its_expiry() {
        let now = Instant::now();
        let mut gate = gate(now);
        assert_eq!(
            gate.redeem(&[5; EnrolmentToken::LEN], now + TTL),
            Err(TokenRefusal::Expired)
        );
        assert!(!gate.is_burned());
        // Positive control: an instant before it, the same token redeems.
        assert_eq!(
            gate.redeem(
                &[5; EnrolmentToken::LEN],
                now + TTL - Duration::from_millis(1)
            ),
            Ok(())
        );
    }

    #[test]
    fn generated_tokens_differ() {
        assert_ne!(generate_token().as_bytes(), generate_token().as_bytes());
    }
}
