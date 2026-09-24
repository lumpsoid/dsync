//! How a measured figure is spelled, in every report and on screen (SPEC
//! §17): one set of formatters, so a value read in the head and the same
//! value pasted out of a copied report never disagree.

use std::time::Duration;

/// µs under a millisecond, ms with one decimal under ten seconds, then s.
pub fn format_duration(value: Duration) -> String {
    let micros = value.as_micros();
    if micros < 1_000 {
        format!("{micros} µs")
    } else if micros < 10_000_000 {
        format!("{:.1} ms", micros as f64 / 1_000.0)
    } else {
        format!("{:.1} s", micros as f64 / 1_000_000.0)
    }
}

/// Bytes in the largest power-of-1024 unit that leaves a number of at
/// least 1.
pub fn format_bytes(value: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut scaled = value as f64;
    let mut unit = 0;
    while scaled >= 1024.0 && unit < UNITS.len() - 1 {
        scaled /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{value} B")
    } else {
        format!("{scaled:.1} {}", UNITS[unit])
    }
}

/// A count with thousands separators: the interesting numbers have five
/// digits, and `14000` and `140000` are not tellable apart at a glance.
pub fn format_count(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, digit) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_pick_their_unit() {
        assert_eq!(format_duration(Duration::from_micros(999)), "999 µs");
        assert_eq!(format_duration(Duration::from_micros(1_500)), "1.5 ms");
        assert_eq!(format_duration(Duration::from_millis(9_999)), "9999.0 ms");
        assert_eq!(format_duration(Duration::from_millis(36_700)), "36.7 s");
    }

    #[test]
    fn bytes_pick_their_unit() {
        assert_eq!(format_bytes(1023), "1023 B");
        assert_eq!(format_bytes(1536), "1.5 KiB");
        assert_eq!(format_bytes(3 * 1024 * 1024), "3.0 MiB");
    }

    #[test]
    fn counts_carry_separators() {
        assert_eq!(format_count(0), "0");
        assert_eq!(format_count(999), "999");
        assert_eq!(format_count(14_471), "14,471");
        assert_eq!(format_count(1_000_000), "1,000,000");
    }
}
