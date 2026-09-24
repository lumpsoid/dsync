//! Lowercase hex for the 32-byte digests the ids and hashes are made of.

pub(crate) fn encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(char::from(DIGITS[usize::from(byte >> 4)]));
        text.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    text
}

/// Exactly `N` bytes from `2 * N` hex digits of either case, or `None`.
pub(crate) fn decode<const N: usize>(text: &str) -> Option<[u8; N]> {
    let digits = text.as_bytes();
    if digits.len() != N * 2 {
        return None;
    }
    let mut bytes = [0u8; N];
    for (byte, pair) in bytes.iter_mut().zip(digits.chunks_exact(2)) {
        *byte = (nibble(pair[0])? << 4) | nibble(pair[1])?;
    }
    Some(bytes)
}

fn nibble(digit: u8) -> Option<u8> {
    char::from(digit)
        .to_digit(16)
        .and_then(|value| u8::try_from(value).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_refuses_bad_digits_or_lengths() {
        let bytes = [0x00, 0x7f, 0xa5, 0xff];
        assert_eq!(encode(&bytes), "007fa5ff");
        assert_eq!(decode::<4>("007fa5ff"), Some(bytes));
        assert_eq!(decode::<4>("007FA5FF"), Some(bytes));
        assert_eq!(decode::<4>("007fa5f"), None);
        assert_eq!(decode::<4>("007fa5fg"), None);
    }
}
